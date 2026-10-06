#import "IrodoriLocalBridge.h"
#import "IrodoriTextConditioning.h"
#include "IrodoriPcmPrefix.h"
#include "IrodoriSamplingSchedule.h"
#import <CommonCrypto/CommonDigest.h>
#import <CoreML/CoreML.h>
#include <mach/mach.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <random>
#include <set>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <malloc/malloc.h>
#include <vector>

// Core ML is the normal app backend. Keep the former implementation only for
// explicit regression builds; other engines may still link ONNX Runtime.
#if !defined(IRODORI_LEGACY_ONNX) && !defined(IRODORI_COREML_ONLY)
#define IRODORI_COREML_ONLY 1
#endif

#if defined(IRODORI_COREML_ONLY)
// Standalone Irodori builds need no ONNX Runtime headers or library.
#elif __has_include(<onnxruntime_cxx_api.h>)
#include <onnxruntime_cxx_api.h>
#include <coreml_provider_factory.h>
#elif __has_include(<onnxruntime-c/onnxruntime_cxx_api.h>)
#include <onnxruntime-c/onnxruntime_cxx_api.h>
#include <onnxruntime-c/coreml_provider_factory.h>
#endif

namespace {
using Clock = std::chrono::steady_clock;
double elapsedMs(Clock::time_point since) {
  return std::chrono::duration<double, std::milli>(Clock::now() - since).count();
}

double physicalFootprintMiB() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return -1;
  return info.phys_footprint / (1024.0 * 1024.0);
}

template <typename F>
auto withInferencePool(bool enabled, F &&operation) -> decltype(operation()) {
  if (enabled) {
    @autoreleasepool { return operation(); }
  }
  return operation();
}

NSString *fileSha256(NSString *path) {
  NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
  if (!stream) return nil;
  [stream open];
  CC_SHA256_CTX hash;
  CC_SHA256_Init(&hash);
  std::vector<uint8_t> buffer(1024 * 1024);
  NSInteger count;
  while ((count = [stream read:buffer.data() maxLength:buffer.size()]) > 0) {
    CC_SHA256_Update(&hash, buffer.data(), static_cast<CC_LONG>(count));
  }
  [stream close];
  if (count < 0) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &hash);
  NSMutableString *result = [NSMutableString stringWithCapacity:64];
  for (unsigned char byte : digest) [result appendFormat:@"%02x", byte];
  return result;
}

bool hasValidatedSplitContext(NSString *root) {
#if defined(IRODORI_COREML_ONLY)
  NSData *data = [NSData dataWithContentsOfFile:
    [root stringByAppendingPathComponent:@"coreml-only.json"]];
  NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [manifest isKindOfClass:NSDictionary.class] &&
    ([manifest[@"format"] isEqual:@"irodori-coreml-only-v1"] ||
     [manifest[@"format"] isEqual:@"irodori-coreml-only-v2"]);
#else
  if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--irodori-context-unsplit"]) {
    return false;
  }
  NSData *data = [NSData dataWithContentsOfFile:
    [root stringByAppendingPathComponent:@"context_kv_split.json"]];
  if (!data) return false;
  id manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![manifest isKindOfClass:[NSDictionary class]] ||
      ![manifest[@"version"] isEqual:@1] ||
      ![manifest[@"files"] isKindOfClass:[NSDictionary class]]) return false;
  if (![fileSha256([root stringByAppendingPathComponent:@"context_kv.onnx"])
        isEqual:manifest[@"sourceSha256"]]) return false;
  for (NSString *name in @[@"context_kv_text.onnx", @"context_kv_speaker.onnx"]) {
    if (![fileSha256([root stringByAppendingPathComponent:name])
          isEqual:manifest[@"files"][name]]) return false;
  }
  return true;
#endif
}

// Core ML compiles .mlpackage models into temporary .mlmodelc directories.
// Keep the compiled result between launches, and invalidate it when any source
// file changes. The cache is purgeable by iOS when storage is needed.
NSURL *compiledCoreMLModel(NSString *sourcePath, NSError **error) {
  auto started = Clock::now();
  NSFileManager *files = [NSFileManager defaultManager];
  // The absolute app-container path can change when iOS updates the app.
  // Keep the cache key stable across installs while distinguishing packages.
  NSMutableString *signature = [NSMutableString stringWithFormat:@"%@/%@",
    sourcePath.stringByDeletingLastPathComponent.lastPathComponent,
    sourcePath.lastPathComponent];
  NSArray<NSString *> *entries = [[[files enumeratorAtPath:sourcePath] allObjects]
    sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *entry in entries) {
    NSDictionary *attributes = [files attributesOfItemAtPath:
      [sourcePath stringByAppendingPathComponent:entry] error:nil];
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
    [signature appendFormat:@"\n%@:%llu:%.6f", entry,
      [attributes[NSFileSize] unsignedLongLongValue],
      [attributes[NSFileModificationDate] timeIntervalSince1970]];
  }
  NSData *signatureData = [signature dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(signatureData.bytes, static_cast<CC_LONG>(signatureData.length), digest);
  NSMutableString *key = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (unsigned char byte : digest) [key appendFormat:@"%02x", byte];
  NSString *cacheBase = NSSearchPathForDirectoriesInDomains(
    NSCachesDirectory, NSUserDomainMask, YES).firstObject;
  static dispatch_once_t migrationOnce;
  dispatch_once(&migrationOnce, ^{
    [files removeItemAtPath:[cacheBase stringByAppendingPathComponent:
      @"irodori-coreml-v1"] error:nil];
    // The v2 DiT was compiled with a 26-token speaker limit. A cached copy
    // would reject longer references even after the package is updated.
    [files removeItemAtPath:[cacheBase stringByAppendingPathComponent:
      @"irodori-coreml-v2"] error:nil];
  });
  NSString *cacheRoot = [cacheBase stringByAppendingPathComponent:
    @"irodori-coreml-v3"];
  if (cacheRoot && [files createDirectoryAtPath:cacheRoot
    withIntermediateDirectories:YES attributes:nil error:nil]) {
    NSString *cachedPath = [cacheRoot stringByAppendingPathComponent:
      [key stringByAppendingPathExtension:@"mlmodelc"]];
    if ([files fileExistsAtPath:cachedPath]) {
      NSString *cachedWeights = [cachedPath stringByAppendingPathComponent:
        @"weights/weight.bin"];
      NSDictionary *cachedAttributes = [files attributesOfItemAtPath:
        cachedWeights error:nil];
      if ([cachedAttributes[NSFileSize] unsignedLongLongValue] > 0) {
        NSLog(@"Irodori Core ML cache hit %@ %.1f ms",
          sourcePath.lastPathComponent, elapsedMs(started));
        return [NSURL fileURLWithPath:cachedPath];
      }
      [files removeItemAtPath:cachedPath error:nil];
    }
    NSURL *compiled = [MLModel compileModelAtURL:[NSURL fileURLWithPath:sourcePath]
                                       error:error];
    if (!compiled) return nil;
    NSURL *cached = [NSURL fileURLWithPath:cachedPath];
    if ([files moveItemAtURL:compiled toURL:cached error:nil]) {
      NSLog(@"Irodori Core ML compiled and cached %@ %.1f ms",
        sourcePath.lastPathComponent, elapsedMs(started));
      return cached;
    }
    NSLog(@"Irodori Core ML compiled without cache %@ %.1f ms",
      sourcePath.lastPathComponent, elapsedMs(started));
    return compiled;
  }
  return [MLModel compileModelAtURL:[NSURL fileURLWithPath:sourcePath]
                             error:error];
}

struct Tensor {
  std::vector<int64_t> shape;
  std::vector<float> floats;
  std::vector<int64_t> integers;
  static Tensor f(std::vector<int64_t> shape, std::vector<float> data) {
    Tensor t; t.shape = std::move(shape); t.floats = std::move(data); return t;
  }
  static Tensor i(std::vector<int64_t> shape, std::vector<int64_t> data) {
    Tensor t; t.shape = std::move(shape); t.integers = std::move(data); return t;
  }
};
using Tensors = std::unordered_map<std::string, Tensor>;

#if defined(IRODORI_COREML_ONLY)
#include "IrodoriCoreMLSession.h"
#endif

class Engine {
 public:
  Engine(const std::string &root, bool useCoreML, bool fastDiT)
      :
#if !defined(IRODORI_COREML_ONLY)
        env_(ORT_LOGGING_LEVEL_WARNING, "irodori"),
#endif
        useCoreML_(useCoreML),
        fastDiT_(fastDiT), root_(root) {
#if defined(IRODORI_COREML_ONLY)
    if (!useCoreML || !fastDiT) throw std::runtime_error("Core ML-only build requires fast DiT");
#endif
    NSString *tokenizerPath = [[NSString stringWithUTF8String:root.c_str()]
      stringByAppendingPathComponent:@"tokenizer/tokenizer.json"];
    NSData *tokenizerData = [NSData dataWithContentsOfFile:tokenizerPath];
    if (!tokenizerData) throw std::runtime_error("tokenizer/tokenizer.json is missing");
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:tokenizerData options:0 error:&jsonError];
    NSArray *vocab = json[@"model"][@"vocab"];
    if (![vocab isKindOfClass:[NSArray class]]) throw std::runtime_error("Invalid tokenizer vocabulary");
    for (NSUInteger id = 0; id < vocab.count; ++id) {
      NSArray *entry = vocab[id];
      if (entry.count != 2) continue;
      std::string piece = [entry[0] UTF8String];
      vocab_[piece] = {static_cast<int64_t>(id), [entry[1] floatValue]};
      maxPieceBytes_ = std::max(maxPieceBytes_, piece.size());
    }
    NSString *rootPath = [NSString stringWithUTF8String:root.c_str()];
    if (@available(iOS 17.0, *)) {
      if (useCoreML_) {
        const bool useMixedLinear = fastDiT_ || [[[NSProcessInfo processInfo] arguments]
          containsObject:@"--irodori-dit-mixed-linear"];
        const bool useMixedMlp = [[[NSProcessInfo processInfo] arguments]
          containsObject:@"--irodori-dit-mixed-mlp"];
        NSArray<NSString *> *ditFilenames = useMixedLinear ?
          @[@"dit_step_cached_mixed_linear_768.mlpackage",
            @"dit_step_cached_mixed_linear_128.mlpackage",
            @"dit_step_cached_fp32_128.mlpackage",
            @"dit_step_cached_fp32.mlpackage"] : useMixedMlp ?
          @[@"dit_step_cached_mixed_mlp_128.mlpackage",
            @"dit_step_cached_fp32_128.mlpackage",
            @"dit_step_cached_fp32.mlpackage"] :
          @[@"dit_step_cached_fp32_768.mlpackage",
            @"dit_step_cached_fp32_128.mlpackage",
            @"dit_step_cached_fp32.mlpackage"];
        for (NSString *filename in ditFilenames) {
          NSString *ditPath = [rootPath stringByAppendingPathComponent:filename];
          if (![[NSFileManager defaultManager] fileExistsAtPath:ditPath]) continue;
          NSError *coreMLError = nil;
          NSURL *compiled = compiledCoreMLModel(ditPath, &coreMLError);
          if (compiled) {
            MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
            const bool allowNeuralEngine = [filename containsString:@"mixed_"] ||
              [[[NSProcessInfo processInfo] arguments]
                containsObject:@"--irodori-dit-cpu-ne"];
            configuration.computeUnits = allowNeuralEngine ?
              MLComputeUnitsCPUAndNeuralEngine : MLComputeUnitsCPUOnly;
            nativeDit_ = [MLModel modelWithContentsOfURL:compiled
                                          configuration:configuration error:&coreMLError];
            if (nativeDit_) nativeDitNeAllowed_ = allowNeuralEngine;
          }
          if (nativeDit_) {
            nativeDitDataType_ = nativeDit_.modelDescription
              .inputDescriptionsByName[@"x_t"].multiArrayConstraint.dataType;
            bool supported = nativeDitDataType_ == MLMultiArrayDataTypeFloat32;
            if (@available(iOS 16.0, *)) {
              supported = supported || nativeDitDataType_ == MLMultiArrayDataTypeFloat16;
            }
            if (!supported) nativeDit_ = nil;
          }
          if (nativeDit_) {
            nativeDitCached_ = [filename hasPrefix:@"dit_step_cached"];
            nativeDitPrecision_ = [filename containsString:@"mixed_linear"] ?
              @"mixed-linear" : [filename containsString:@"mixed_mlp"] ?
              @"mixed-mlp" : @"float32";
            maxLatentFrames_ = [filename containsString:@"_768."] ? 768 :
              ([filename containsString:@"_128."] ? 128 : 64);
            maxTextTokens_ = maxLatentFrames_ == 768 ? 256 : 64;
            break;
          }
          NSLog(@"Irodori native Core ML DiT unavailable: %@", coreMLError);
        }
        bool allStagesPresent = [[NSFileManager defaultManager] fileExistsAtPath:
#if defined(IRODORI_COREML_ONLY)
          [rootPath stringByAppendingPathComponent:@"decoder_stage_0.mlpackage"]];
#else
          [rootPath stringByAppendingPathComponent:@"decoder_stage_0.onnx"]];
#endif
        NSString *sharedStage1 = @"decoder_stage_1_multifunction.mlpackage";
        const bool useSharedStage1 = [[NSFileManager defaultManager] fileExistsAtPath:
          [rootPath stringByAppendingPathComponent:sharedStage1]] &&
          ![[NSFileManager defaultManager] fileExistsAtPath:
            [rootPath stringByAppendingPathComponent:@"decoder_stage_1_2d_fixed_w64.mlpackage"]];
        if (useSharedStage1) {
          if (@available(iOS 18.0, macOS 15.0, *)) {} else {
            throw std::runtime_error("Shared decoder models require iOS 18 or macOS 15");
          }
        }
        for (int stage = 1; stage <= 3; ++stage) {
          NSString *standard = [NSString stringWithFormat:@"decoder_stage_%d_2d.mlpackage", stage];
          NSString *optimized = stage == 1 ? (useSharedStage1 ? sharedStage1 : @"decoder_stage_1_2d_fixed_w64.mlpackage") :
            (stage == 2 ? @"decoder_stage_2_2d_fixed_w256.mlpackage" :
             @"decoder_stage_3_2d_w511.mlpackage");
          allStagesPresent &= [[NSFileManager defaultManager] fileExistsAtPath:
            [rootPath stringByAppendingPathComponent:standard]] ||
            [[NSFileManager defaultManager] fileExistsAtPath:
             [rootPath stringByAppendingPathComponent:optimized]] ||
            (stage == 1 && [[NSFileManager defaultManager] fileExistsAtPath:
             [rootPath stringByAppendingPathComponent:@"decoder_stage_1_2d_w128.mlpackage"]]);
        }
        if (allStagesPresent) {
          for (int stage = 1; stage <= 3; ++stage) {
            MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
            // Fixed-shape stages 1 and 2 accept Neural Engine execution.
            // Their flexible-shape variants use CPU/GPU after preparation
            // failed on the iPhone 17 Pro test device.
            NSString *fixedStage1 = useSharedStage1 ? sharedStage1 : @"decoder_stage_1_2d_fixed_w64.mlpackage";
            const bool useFixedStage1 = stage == 1 &&
              [[NSFileManager defaultManager] fileExistsAtPath:
               [rootPath stringByAppendingPathComponent:fixedStage1]];
            NSString *fixedStage2 = @"decoder_stage_2_2d_fixed_w256.mlpackage";
            const bool useFixedStage2 = stage == 2 &&
              [[NSFileManager defaultManager] fileExistsAtPath:
               [rootPath stringByAppendingPathComponent:fixedStage2]];
            const bool stage3ANE = stage == 3 && ![[[NSProcessInfo processInfo] arguments]
              containsObject:@"--irodori-stage3-gpu"];
            const bool allowANE = stage3ANE || useFixedStage1 || useFixedStage2;
            configuration.computeUnits = allowANE ? MLComputeUnitsAll : MLComputeUnitsCPUAndGPU;
            stagedDecoderModes_[stage - 1] = allowANE ? 0 : 1;
            NSString *filename = [NSString stringWithFormat:@"decoder_stage_%d_2d.mlpackage", stage];
            if (useFixedStage1) {
              filename = fixedStage1;
              if (useSharedStage1) {
                if (@available(iOS 18.0, macOS 15.0, *)) configuration.functionName = @"w64";
              }
              stagedDecoderFixed_[stage - 1] = true;
              stagedDecoderWidths_[stage - 1] = 64;
            } else if (stage == 1 && [[NSFileManager defaultManager] fileExistsAtPath:
                        [rootPath stringByAppendingPathComponent:@"decoder_stage_1_2d_w128.mlpackage"]]) {
              filename = @"decoder_stage_1_2d_w128.mlpackage";
              stagedDecoderWidths_[stage - 1] = 128;
            } else if (useFixedStage2) {
              filename = fixedStage2;
              stagedDecoderFixed_[stage - 1] = true;
              stagedDecoderWidths_[stage - 1] = 256;
            } else if (stage == 2 || stage == 3) {
              const int largerWidth = stage == 2 ? 256 : 511;
              NSString *larger = [NSString stringWithFormat:
                @"decoder_stage_%d_2d_w%d.mlpackage", stage, largerWidth];
              if ([[NSFileManager defaultManager] fileExistsAtPath:
                   [rootPath stringByAppendingPathComponent:larger]]) {
                filename = larger;
                stagedDecoderWidths_[stage - 1] = largerWidth;
              }
            }
            NSString *path = [rootPath stringByAppendingPathComponent:filename];
            NSError *coreMLError = nil;
            NSURL *compiled = compiledCoreMLModel(path, &coreMLError);
            if (compiled) {
              stagedDecoderCompiledUrls_[stage - 1] = compiled;
              stagedDecoderModels_[stage - 1] = [MLModel modelWithContentsOfURL:compiled
                configuration:configuration error:&coreMLError];
            }
            if (!stagedDecoderModels_[stage - 1]) {
              NSLog(@"Irodori 2D Core ML decoder stage %d unavailable: %@", stage,
                    coreMLError);
              stagedDecoderModels_ = {};
              stagedDecoderCompiledUrls_ = {};
              break;
            }
          }
          stagedDecoder_ = stagedDecoderModels_[0] && stagedDecoderModels_[1] &&
                           stagedDecoderModels_[2];
          if (stagedDecoder_ && ![[[NSProcessInfo processInfo] arguments]
                containsObject:@"--irodori-stage3-serial"]) {
            MLModelConfiguration *parallelConfiguration = [[MLModelConfiguration alloc] init];
            parallelConfiguration.computeUnits = MLComputeUnitsAll;
            NSError *parallelError = nil;
            stagedDecoderStage3Parallel_ = [MLModel modelWithContentsOfURL:
              stagedDecoderCompiledUrls_[2] configuration:parallelConfiguration
                                       error:&parallelError];
            if (!stagedDecoderStage3Parallel_) {
              NSLog(@"Irodori parallel decoder model unavailable: %@", parallelError);
            }
          }
          if (stagedDecoder_ && stagedDecoderFixed_[0]) {
            NSString *fixed57Path = [rootPath stringByAppendingPathComponent:
              useSharedStage1 ? sharedStage1 : @"decoder_stage_1_2d_fixed_w57.mlpackage"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:fixed57Path]) {
              NSError *fixed57Error = nil;
              NSURL *compiled = useSharedStage1 ? stagedDecoderCompiledUrls_[0] :
                compiledCoreMLModel(fixed57Path, &fixed57Error);
              if (compiled) {
                MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
                configuration.computeUnits = MLComputeUnitsAll;
                if (useSharedStage1) {
                  if (@available(iOS 18.0, macOS 15.0, *)) configuration.functionName = @"w57";
                }
                stagedDecoderStage1Fixed57_ = [MLModel modelWithContentsOfURL:compiled
                  configuration:configuration error:&fixed57Error];
              }
              if (!stagedDecoderStage1Fixed57_) {
                NSLog(@"Irodori fixed-57 decoder stage 1 unavailable: %@", fixed57Error);
              }
            }
            // Some iOS runtimes cannot prepare a flexible function inside a
            // multifunction program. A separately packaged flexible function
            // can retain the original GPU plan while fixed functions share weights.
            NSString *standaloneFlexibleStage1 = @"decoder_stage_1_2d_w128.mlpackage";
            const bool hasStandaloneFlexibleStage1 = [[NSFileManager defaultManager] fileExistsAtPath:
              [rootPath stringByAppendingPathComponent:standaloneFlexibleStage1]];
            NSArray<NSString *> *flexibleStage1Names = useSharedStage1 ?
              (hasStandaloneFlexibleStage1 ? @[standaloneFlexibleStage1, sharedStage1] : @[sharedStage1]) :
              @[standaloneFlexibleStage1, @"decoder_stage_1_2d.mlpackage"];
            for (NSString *flexibleName in flexibleStage1Names) {
              NSString *flexiblePath = [rootPath stringByAppendingPathComponent:flexibleName];
              if (![[NSFileManager defaultManager] fileExistsAtPath:flexiblePath]) continue;
              NSError *flexibleError = nil;
              const bool sharedFlexibleFunction = useSharedStage1 && [flexibleName isEqualToString:sharedStage1];
              NSURL *compiled = sharedFlexibleFunction ? stagedDecoderCompiledUrls_[0] :
                compiledCoreMLModel(flexiblePath, &flexibleError);
              if (compiled) {
                MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
                configuration.computeUnits = MLComputeUnitsCPUAndGPU;
                if (sharedFlexibleFunction) {
                  if (@available(iOS 18.0, macOS 15.0, *)) configuration.functionName = @"w128";
                }
                stagedDecoderStage1Flexible_ = [MLModel modelWithContentsOfURL:compiled
                  configuration:configuration error:&flexibleError];
              }
              if (stagedDecoderStage1Flexible_) break;
              if (!stagedDecoderStage1Flexible_) {
                NSLog(@"Irodori flexible decoder stage 1 unavailable: %@", flexibleError);
              }
            }
          }
          if (stagedDecoder_ && [[[NSProcessInfo processInfo] arguments]
                containsObject:@"--irodori-stage1-enumerated"]) {
            NSString *enumPath = [rootPath stringByAppendingPathComponent:
              @"decoder_stage_1_2d_enum.mlpackage"];
            NSString *manifestPath = [rootPath stringByAppendingPathComponent:
              @"decoder_stage_1_2d_enum.json"];
            NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
            NSDictionary *manifest = manifestData ?
              [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
            NSArray *widths = manifest[@"widths"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:enumPath] &&
                [widths isKindOfClass:[NSArray class]]) {
              NSError *enumError = nil;
              NSURL *compiled = compiledCoreMLModel(enumPath, &enumError);
              if (compiled) {
                MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
                configuration.computeUnits = MLComputeUnitsAll;
                stagedDecoderStage1Enumerated_ = [MLModel modelWithContentsOfURL:compiled
                  configuration:configuration error:&enumError];
              }
              if (stagedDecoderStage1Enumerated_) {
                for (NSNumber *width in widths) {
                  stagedDecoderStage1EnumeratedWidths_.insert(width.longLongValue);
                }
              } else {
                NSLog(@"Irodori enumerated decoder stage 1 unavailable: %@", enumError);
              }
            }
          }
        }
        NSString *packagePath = [rootPath stringByAppendingPathComponent:
          @"native_decoder/decoder.mlpackage"];
        if (!stagedDecoder_ && [[NSFileManager defaultManager] fileExistsAtPath:packagePath]) {
          NSError *coreMLError = nil;
          NSURL *compiled = compiledCoreMLModel(packagePath, &coreMLError);
          if (compiled) {
            MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
            // The supplied decoder was converted for GPU execution. The DiT
            // has a separate Core ML execution-provider path eligible for ANE.
            configuration.computeUnits = MLComputeUnitsCPUAndGPU;
            nativeDecoder_ = [MLModel modelWithContentsOfURL:compiled
                                              configuration:configuration error:&coreMLError];
          }
          if (!nativeDecoder_) {
            NSLog(@"Irodori native Core ML decoder unavailable: %@", coreMLError);
          }
        }
      }
    }
#if defined(IRODORI_COREML_ONLY)
    if (!nativeDit_ || !nativeDitCached_ || ![nativeDitPrecision_ isEqual:@"mixed-linear"] || !stagedDecoder_ ||
        !hasValidatedSplitContext(rootPath))
      throw std::runtime_error("Incomplete Core ML-only model bundle");
#endif
    splitDecoder_ = true;
    for (int stage = 0; stage < 4; ++stage) {
      NSString *filename = [NSString stringWithFormat:@"decoder_stage_%d.onnx", stage];
      if (![[NSFileManager defaultManager] fileExistsAtPath:
            [rootPath stringByAppendingPathComponent:filename]]) splitDecoder_ = false;
    }
    const NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
    // Keep a comparison switch for the previous eager-loading behavior.
    // Weight values, providers and inference precision are unchanged.
    trimAuxiliarySessions_ = ![arguments containsObject:@"--irodori-keep-auxiliary-sessions"];
    std::vector<std::string> names = {"text_encoder", "speaker_encoder", "duration",
                                      "dacvae_encode"};
    if (!nativeDit_ || nativeDitCached_) {
      splitContext_ = hasValidatedSplitContext(rootPath);
      if (splitContext_) {
        names.push_back("context_kv_text");
        names.push_back("context_kv_speaker");
      } else {
        names.push_back("context_kv");
      }
    }
    if (!nativeDit_) {
      names.push_back("dit_step");
    }
    if (stagedDecoder_) {
      names.push_back("decoder_stage_0");
#if !defined(IRODORI_COREML_ONLY)
      if (stagedDecoderFixed_[0] &&
          (!stagedDecoderStage1Flexible_ || maxLatentFrames_ > 64) &&
          [[NSFileManager defaultManager] fileExistsAtPath:
           [rootPath stringByAppendingPathComponent:@"decoder_stage_1.onnx"]]) {
        stage1OnnxFallbackAvailable_ = true;
        // Core ML handles normal synthesis. Keep the fallback available on
        // disk without loading its weights and execution provider until used.
        if (!trimAuxiliarySessions_) names.push_back("decoder_stage_1");
      }
#endif
    } else if (!nativeDecoder_) {
    if (splitDecoder_) {
        for (int stage = 0; stage < 4; ++stage) {
          names.push_back("decoder_stage_" + std::to_string(stage));
        }
        hasFixedStage3_ = [[NSFileManager defaultManager] fileExistsAtPath:
          [rootPath stringByAppendingPathComponent:@"decoder_stage_3_256.onnx"]];
        if (hasFixedStage3_) names.push_back("decoder_stage_3_256");
      } else {
        names.push_back("dacvae_decode");
      }
    }
    innerPools_ = [arguments containsObject:@"--irodori-inner-pools"];
    profileInference_ = [arguments containsObject:@"--irodori-diagnostics"] ||
      [arguments containsObject:@"--irodori-benchmark"];
    fixedSeed_ = [arguments containsObject:@"--irodori-fixed-seed"];
    compactWeights_ = ![arguments containsObject:@"--irodori-legacy-weight-arena"];
    stopIdleSpin_ = [arguments containsObject:@"--irodori-stop-idle-spin"];
    transientReference_ = ![arguments containsObject:@"--irodori-keep-reference-sessions"];
    recomputeReference_ = [arguments containsObject:@"--irodori-reference-recompute"];
    quantizedTextEncoder_ = [arguments containsObject:@"--irodori-text-qint8"];
    onnxAllowSpinning_ = ![arguments containsObject:@"--irodori-onnx-no-spin"];
    const NSUInteger threadIndex = [arguments indexOfObject:@"--irodori-onnx-threads"];
    if (threadIndex != NSNotFound && threadIndex + 1 < arguments.count) {
      const NSInteger requested = arguments[threadIndex + 1].integerValue;
      if (requested >= 1 && requested <= 8) onnxThreads_ = static_cast<int>(requested);
    }
    for (const std::string &name : names) {
      if (transientReference_ && name == "dacvae_encode") continue;
      loadOnnxSession(name);
    }
    Tensors speakerInputs;
    speakerInputs.emplace("ref_latent", Tensor::f({1, 4, 32}, std::vector<float>(128, 0.f)));
    speakerInputs.emplace("mask", Tensor::f({1, 4}, std::vector<float>(4, 0.f)));
    noRefSpeaker_ = run("speaker_encoder", speakerInputs);
    // Retain this session until reference registration, so an uncached first
    // reference can reuse it. Registration or the first synthesis releases it.
  }

  bool referenceCacheHit() const { return referenceCacheHit_; }

  void setReference(const float *samples, size_t count) {
    referenceCacheHit_ = false;
    cachedSpeakerContext_.clear();
    cachedSpeakerContextBytes_ = 0;
    if (count == 0) {
      referenceSpeaker_.clear();
      if (transientReference_) releaseReferenceSessions();
      return;
    }
    if (count < 1920 || count > 48000 * 120) {
      throw std::runtime_error("Reference must be between 40 ms and 120 s at 48 kHz");
    }
    NSString *cachePath = referenceCachePath(samples, count);
    if (!recomputeReference_ && cachePath && loadCachedReference(cachePath)) {
      referenceCacheHit_ = true;
      if (transientReference_) releaseReferenceSessions();
      return;
    }
    try {
      if (transientReference_) loadReferenceSessions();
      encodeReference(samples, count);
      if (!recomputeReference_ && cachePath) saveCachedReference(cachePath);
    } catch (...) {
      if (transientReference_) releaseReferenceSessions();
      throw;
    }
    if (transientReference_) releaseReferenceSessions();
  }

  void encodeReference(const float *samples, size_t count) {
    std::vector<float> waveform(samples, samples + count);
    double sumSquares = 0;
    for (float sample : waveform) sumSquares += sample * sample;
    double rms = std::sqrt(sumSquares / waveform.size());
    if (rms > 1e-5) {
      float scale = static_cast<float>(std::pow(10.0, -16.0 / 20.0) / rms);
      float peak = 0;
      for (float sample : waveform) peak = std::max(peak, std::abs(sample * scale));
      if (peak > 1.f) scale /= peak;
      for (float &sample : waveform) sample *= scale;
    }
    Tensors encoderInputs;
    encoderInputs.emplace("waveform", Tensor::f({1, 1, static_cast<int64_t>(count)},
                                              std::move(waveform)));
    Tensors encoded = run("dacvae_encode", encoderInputs);
    Tensor latent = encoded.at("latent");
    int64_t frames = latent.shape.at(1);
    if (frames <= 0 || latent.shape.at(2) != 32) {
      throw std::runtime_error("Reference encoder returned invalid latent shape");
    }
#if defined(IRODORI_COREML_ONLY)
    if (frames < 4) throw std::runtime_error("Reference audio needs at least four latent frames (160 ms)");
#endif
    // Keep the entire reference latent. v4.1 was trained with up to 120 s of
    // reference audio; silently taking only the first 100 frames changed the
    // selected speaker and made longer references behave unpredictably.
    Tensors speakerInputs;
    speakerInputs.emplace("ref_latent", std::move(latent));
    speakerInputs.emplace("mask", Tensor::f({1, frames}, std::vector<float>(frames, 1.f)));
    referenceSpeaker_ = run("speaker_encoder", speakerInputs);
  }

  void releaseReferenceSessions() {
    size_t released = sessions_.erase("speaker_encoder");
    released += sessions_.erase("dacvae_encode");
    if (trimAuxiliarySessions_ && released) releaseUnusedHeap();
  }

  void releaseUnusedHeap() {
    // Session destruction frees weights, but malloc may retain their pages.
    // Return only unused allocations, once at a model lifecycle transition;
    // never purge the live inference arena or run this on every utterance.
    const auto started = Clock::now();
    auxiliaryHeapReleasedBytes_ += malloc_zone_pressure_relief(nullptr, 0);
    auxiliaryHeapReliefMs_ += elapsedMs(started);
  }

#if !defined(IRODORI_COREML_ONLY)
  Ort::SessionOptions cpuSessionOptions() const {
    Ort::SessionOptions options;
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_EXTENDED);
    options.SetIntraOpNumThreads(onnxThreads_);
    if (stopIdleSpin_) options.AddConfigEntry("session.force_spinning_stop", "1");
    if (compactWeights_) {
      // Keep exact weight values, but allocate long-lived initializers outside
      // the growing inference arena. This avoids retaining large unused arena
      // regions alongside the LLM and Core ML models on memory-limited devices.
      options.AddConfigEntry("session.use_device_allocator_for_initializers", "1");
    }
    if (!onnxAllowSpinning_) {
      options.AddConfigEntry("session.intra_op.allow_spinning", "0");
      options.AddConfigEntry("session.inter_op.allow_spinning", "0");
    }
    return options;
  }
#endif

  void loadReferenceSessions() {
    for (const char *name : {"dacvae_encode", "speaker_encoder"}) {
      if (sessions_.count(name)) continue;
#if defined(IRODORI_COREML_ONLY)
      loadOnnxSession(name);
#else
      const std::string path = root_ + "/" + name + ".onnx";
      Ort::SessionOptions options = cpuSessionOptions();
      sessions_.emplace(name, std::make_unique<Ort::Session>(env_, path.c_str(), options));
#endif
    }
  }

  void loadOnnxSession(const std::string &name) {
    if (sessions_.count(name)) return;
#if defined(IRODORI_COREML_ONLY)
    sessions_.emplace(name, std::make_unique<IrodoriCoreMLSession>(
      [NSString stringWithUTF8String:root_.c_str()], name));
#else
    const std::string filename = name == "text_encoder" && quantizedTextEncoder_ ?
      "text_encoder_qint8.onnx" : name + ".onnx";
    NSString *path = [[NSString stringWithUTF8String:root_.c_str()]
      stringByAppendingPathComponent:[NSString stringWithUTF8String:filename.c_str()]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
      throw std::runtime_error("Missing model: " + filename);
    }
    Ort::SessionOptions opts = cpuSessionOptions();
    // Use exactly the same provider, graph optimization and precision for
    // eager and on-demand loading. ONNX DiT remains on CPU.
    if (useCoreML_ && (name == "dacvae_decode" ||
        name.rfind("decoder_stage_", 0) == 0)) {
      OrtStatus *status = OrtSessionOptionsAppendExecutionProvider_CoreML(
        opts, COREML_FLAG_ENABLE_ON_SUBGRAPH);
      if (status != nullptr) Ort::GetApi().ReleaseStatus(status);
    }
    try {
      sessions_.emplace(name, std::make_unique<Ort::Session>(env_, path.fileSystemRepresentation, opts));
    } catch (const Ort::Exception &) {
      if (!useCoreML_ || (name != "dit_step" && name != "dacvae_decode" &&
          name.rfind("decoder_stage_", 0) != 0)) throw;
      Ort::SessionOptions cpu = cpuSessionOptions();
      sessions_.emplace(name, std::make_unique<Ort::Session>(env_, path.fileSystemRepresentation, cpu));
    }
#endif
    ++sessionLoadCounts_[name];
  }

  NSString *referenceCachePath(const float *samples, size_t count) const {
    NSString *cacheBase = NSSearchPathForDirectoriesInDomains(
      NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cacheBase) return nil;
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *directory = [cacheBase stringByAppendingPathComponent:
#if defined(IRODORI_COREML_ONLY)
      @"irodori-reference-coreml-v1"];
#else
      @"irodori-reference-v1"];
#endif
    if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES
                           attributes:nil error:nil]) return nil;
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    CC_SHA256_Update(&hash, samples, static_cast<CC_LONG>(count * sizeof(float)));
    NSString *rootPath = [NSString stringWithUTF8String:root_.c_str()];
    NSMutableArray<NSString *> *referenceFiles = [NSMutableArray array];
#if defined(IRODORI_COREML_ONLY)
    for (NSString *component in @[@"dacvae_encode_stats", @"speaker_encoder"]) {
      [referenceFiles addObject:[component stringByAppendingPathExtension:@"json"]];
      NSString *package = [component stringByAppendingPathExtension:@"mlpackage"];
      for (NSString *entry in [[[files enumeratorAtPath:
          [rootPath stringByAppendingPathComponent:package]] allObjects]
          sortedArrayUsingSelector:@selector(compare:)]) {
        [referenceFiles addObject:[package stringByAppendingPathComponent:entry]];
      }
    }
#else
    [referenceFiles addObjectsFromArray:@[@"dacvae_encode.onnx", @"speaker_encoder.onnx"]];
#endif
    for (NSString *name in referenceFiles) {
      NSDictionary *attributes = [files attributesOfItemAtPath:
        [rootPath stringByAppendingPathComponent:name] error:nil];
      NSString *signature = [NSString stringWithFormat:@"%@:%llu:%.6f", name,
        [attributes[NSFileSize] unsignedLongLongValue],
        [attributes[NSFileModificationDate] timeIntervalSince1970]];
      NSData *encoded = [signature dataUsingEncoding:NSUTF8StringEncoding];
      CC_SHA256_Update(&hash, encoded.bytes, static_cast<CC_LONG>(encoded.length));
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hash);
    NSMutableString *key = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (unsigned char byte : digest) [key appendFormat:@"%02x", byte];
    return [directory stringByAppendingPathComponent:
      [key stringByAppendingPathExtension:@"plist"]];
  }

  bool loadCachedReference(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return false;
    NSDictionary *archive = [NSPropertyListSerialization propertyListWithData:data
      options:NSPropertyListImmutable format:nil error:nil];
    if (![archive isKindOfClass:[NSDictionary class]]) return false;
    const int64_t frames = [archive[@"frames"] longLongValue];
    NSData *stateData = archive[@"state"];
    NSData *maskData = archive[@"mask"];
    if (frames < 1 || frames > 751 || ![stateData isKindOfClass:[NSData class]] ||
        ![maskData isKindOfClass:[NSData class]] ||
        stateData.length != static_cast<NSUInteger>(frames * 768 * sizeof(float)) ||
        maskData.length != static_cast<NSUInteger>(frames * sizeof(float))) return false;
    std::vector<float> state(frames * 768);
    std::vector<float> mask(frames);
    std::memcpy(state.data(), stateData.bytes, stateData.length);
    std::memcpy(mask.data(), maskData.bytes, maskData.length);
    if (std::any_of(state.begin(), state.end(), [](float x) { return !std::isfinite(x); }) ||
        std::any_of(mask.begin(), mask.end(), [](float x) { return !std::isfinite(x); })) return false;
    referenceSpeaker_.clear();
    referenceSpeaker_.emplace("speaker_state", Tensor::f({1, frames, 768}, std::move(state)));
    referenceSpeaker_.emplace("speaker_mask", Tensor::f({1, frames}, std::move(mask)));
    NSLog(@"Irodori reference feature cache hit (%lld tokens)", frames);
    return true;
  }

  void saveCachedReference(NSString *path) const {
    const Tensor &state = referenceSpeaker_.at("speaker_state");
    const Tensor &mask = referenceSpeaker_.at("speaker_mask");
    if (state.shape.size() != 3 || state.shape[0] != 1 || state.shape[2] != 768 ||
        mask.shape != std::vector<int64_t>{1, state.shape[1]}) return;
    NSDictionary *archive = @{
      @"frames": @(state.shape[1]),
      @"state": [NSData dataWithBytes:state.floats.data()
                                 length:state.floats.size() * sizeof(float)],
      @"mask": [NSData dataWithBytes:mask.floats.data()
                                length:mask.floats.size() * sizeof(float)],
    };
    NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:archive
      format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (encoded) [encoded writeToFile:path options:NSDataWritingAtomic error:nil];
  }

  std::vector<int64_t> tokenize(NSString *source) const {
    NSMutableString *normalized = [source mutableCopy];
    for (NSArray<NSString *> *pair in @[@[@"？", @"?"], @[@"！", @"!"], @[@"　", @""],
                                        @[@"\t", @""], @[@"[n]", @""], @[@"〜", @"ー"]]) {
      [normalized replaceOccurrencesOfString:pair[0] withString:pair[1]
                                    options:0 range:NSMakeRange(0, normalized.length)];
    }
    [normalized setString:[normalized precomposedStringWithCompatibilityMapping]];
    for (NSArray<NSString *> *pair in @[@[@"...", @"…"], @[@"..", @"…"], @[@" ", @"▁"]]) {
      [normalized replaceOccurrencesOfString:pair[0] withString:pair[1]
                                    options:0 range:NSMakeRange(0, normalized.length)];
    }
    std::string s = normalized.UTF8String;
    std::vector<size_t> boundaries{0};
    for (size_t p = 1; p < s.size(); ++p) {
      if ((static_cast<unsigned char>(s[p]) & 0xC0) != 0x80) boundaries.push_back(p);
    }
    boundaries.push_back(s.size());
    const size_t count = boundaries.size() - 1;
    std::vector<double> best(count + 1, -std::numeric_limits<double>::infinity());
    std::vector<size_t> previous(count + 1, 0);
    std::vector<int64_t> chosen(count + 1, 0);
    best[0] = 0;
    for (size_t i = 0; i < count; ++i) {
      if (!std::isfinite(best[i])) continue;
      for (size_t j = i + 1; j <= count && boundaries[j] - boundaries[i] <= maxPieceBytes_; ++j) {
        auto found = vocab_.find(s.substr(boundaries[i], boundaries[j] - boundaries[i]));
        if (found == vocab_.end()) continue;
        double score = best[i] + found->second.second;
        if (score > best[j]) { best[j] = score; previous[j] = i; chosen[j] = found->second.first; }
      }
      if (!std::isfinite(best[i + 1])) {
        best[i + 1] = best[i] - 100;
        previous[i + 1] = i;
        chosen[i + 1] = 0;
      }
    }
    std::vector<int64_t> reversed;
    for (size_t p = count; p > 0; p = previous[p]) {
      if (chosen[p] != 0) { reversed.push_back(chosen[p]); continue; }
      for (size_t b = boundaries[p]; b > boundaries[previous[p]];) {
        --b;
        char token[7]; snprintf(token, sizeof(token), "<0x%02X>", (unsigned char)s[b]);
        auto found = vocab_.find(token);
        reversed.push_back(found == vocab_.end() ? 0 : found->second.first);
      }
    }
    std::reverse(reversed.begin(), reversed.end());
    std::vector<int64_t> result{1}; // Upstream prepends BOS and omits EOS.
    for (int64_t id : reversed) {
      result.push_back(id);
    }
    return result;
  }

  NSDictionary<NSString *, id> *synthesize(NSString *text, NSString *caption,
                                        NSNumber *requestedSeed,
                                        IrodoriPcmCallback onPcm = nil) {
    const auto synthesisStarted = Clock::now();
    // Also cover callers that synthesize with the default voice without ever
    // invoking setReference. Only the encoded speaker features are needed.
    if (transientReference_) releaseReferenceSessions();
    NSMutableDictionary *metrics = [NSMutableDictionary dictionary];
#if defined(IRODORI_COREML_ONLY)
    metrics[@"auxiliaryBackend"] = @"coreml-fp32";
#else
    metrics[@"auxiliaryBackend"] = @"onnx";
#endif
    size_t chunkCount = 0, streamedSamples = 0;
    IrodoriPcmPrefix prefix(onPcm ? IrodoriPcmPrefix::Sink([&](const std::vector<int16_t> &chunk) {
      if (chunkCount++ == 0) metrics[@"incrementalFirstPcmMs"] = @(elapsedMs(synthesisStarted));
      streamedSamples += chunk.size();
      onPcm([NSData dataWithBytes:chunk.data() length:chunk.size() * sizeof(int16_t)]);
    }) : IrodoriPcmPrefix::Sink{});
    if (profileInference_) metrics[@"physicalFootprintStartMiB"] = @(physicalFootprintMiB());
    metrics[@"inferenceInnerPools"] = @(innerPools_ ? 1 : 0);
    metrics[@"onnxCompactWeights"] = @(compactWeights_ ? 1 : 0);
    metrics[@"onnxStopIdleSpin"] = @(stopIdleSpin_ ? 1 : 0);
    metrics[@"referenceEncoderSessionsResident"] =
      @(sessions_.count("speaker_encoder") + sessions_.count("dacvae_encode"));
    metrics[@"thermalState"] = @([[NSProcessInfo processInfo] thermalState]);
    auto mark = Clock::now();
    auto ids = tokenize(text);
    metrics[@"originalTextTokens"] = @(ids.size());
    NSString *modelText = text;
    if (![[[NSProcessInfo processInfo] arguments]
          containsObject:@"--irodori-keep-outer-brackets"]) {
      modelText = IrodoriTextWithoutOuterBrackets(text);
      if (![modelText isEqualToString:text]) {
        ids = tokenize(modelText);
        metrics[@"outerTextBracketsRemoved"] = @1;
      }
    }
    if (![[[NSProcessInfo processInfo] arguments]
          containsObject:@"--irodori-keep-short-period"]) {
      NSString *conditioningText = IrodoriTextForConditioning(modelText, ids.size());
      if (![conditioningText isEqualToString:modelText]) {
        ids = tokenize(conditioningText);
        metrics[@"shortTextStopRemoved"] = @1;
      }
    }
    metrics[@"tokenizeMs"] = @(elapsedMs(mark));
    if (ids.size() <= 1) throw std::runtime_error("Text is empty after tokenization");
    if (ids.size() > maxTextTokens_) {
      throw std::runtime_error("Irodori sentence exceeds model limit (tokens)");
    }
    const int64_t length = static_cast<int64_t>(ids.size());
    metrics[@"textTokens"] = @(length);
    if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--irodori-benchmark"]) {
      NSMutableArray<NSNumber *> *tokenIds = [NSMutableArray arrayWithCapacity:ids.size()];
      for (int64_t id : ids) [tokenIds addObject:@(id)];
      metrics[@"tokenIds"] = tokenIds;
    }
    auto textMask = std::vector<float>(ids.size(), 1.f);
    mark = Clock::now();
    Tensors textInputs;
    textInputs.emplace("input_ids", Tensor::i({1, length}, std::move(ids)));
    textInputs.emplace("mask", Tensor::f({1, length}, textMask));
    Tensors textOut = run("text_encoder", textInputs);
    metrics[@"textEncoderMs"] = @(elapsedMs(mark));

    mark = Clock::now();
    const Tensors &speakerOut = referenceSpeaker_.empty() ? noRefSpeaker_ : referenceSpeaker_;
    metrics[@"speakerLookupMs"] = @(elapsedMs(mark));
    auto &speaker = speakerOut.at("speaker_state");
    auto &speakerMask = speakerOut.at("speaker_mask");
    NSString *voiceInstruction = [caption stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    const bool hasCaption = voiceInstruction.length > 0;
    const Tensor *captionState = &textOut.at("caption_state");
    auto captionMask = Tensor::f({1, length}, std::vector<float>(length, 0.f));
    metrics[@"captionEnabled"] = @(hasCaption ? 1 : 0);
    metrics[@"captionEncoderMs"] = @0;
    metrics[@"captionCacheHit"] = @0;
    metrics[@"captionTokens"] = @0;
    if (hasCaption) {
      mark = Clock::now();
      const std::string key = voiceInstruction.UTF8String;
      const bool hit = key == cachedCaptionText_ && !cachedCaption_.floats.empty();
      if (!hit) {
        auto captionIds = tokenize(voiceInstruction);
        if (captionIds.size() <= 1) throw std::runtime_error("Voice instruction is empty after tokenization");
        if (captionIds.size() > maxTextTokens_) {
          throw std::runtime_error("Irodori voice instruction exceeds model limit (256 tokens); shorten the instruction");
        }
        const int64_t captionLength = static_cast<int64_t>(captionIds.size());
        Tensors inputs;
        inputs.emplace("input_ids", Tensor::i({1, captionLength}, std::move(captionIds)));
        inputs.emplace("mask", Tensor::f({1, captionLength}, std::vector<float>(captionLength, 1.f)));
        auto encoded = run("text_encoder", inputs);
        cachedCaption_ = std::move(encoded.at("caption_state"));
        cachedCaptionText_ = key;
      }
      captionState = &cachedCaption_;
      const int64_t captionLength = captionState->shape.at(1);
      captionMask = Tensor::f({1, captionLength}, std::vector<float>(captionLength, 1.f));
      metrics[@"captionTokens"] = @(captionLength);
      metrics[@"captionCacheHit"] = @(hit ? 1 : 0);
      metrics[@"captionEncoderMs"] = @(elapsedMs(mark));
    } else {
      cachedCaption_ = Tensor{};
      cachedCaptionText_.clear();
    }

    mark = Clock::now();
    Tensors durationInputs;
    durationInputs.emplace("text_state", textOut.at("text_state"));
    durationInputs.emplace("text_mask", Tensor::f({1, length}, textMask));
    durationInputs.emplace("speaker_state", speaker);
    durationInputs.emplace("has_speaker", Tensor::f({1}, {referenceSpeaker_.empty() ? 0.f : 1.f}));
    durationInputs.emplace("caption_state", *captionState);
    durationInputs.emplace("caption_mask", captionMask);
    durationInputs.emplace("has_caption", Tensor::f({1}, {hasCaption ? 1.f : 0.f}));
    Tensors durationOut = run("duration", durationInputs);
    float logFrames = durationOut.at("log_frames").floats.at(0);
    if (!std::isfinite(logFrames)) throw std::runtime_error("Duration model returned nonfinite output");
    double predictedFrames = std::expm1(static_cast<double>(logFrames));
    if (!std::isfinite(predictedFrames)) throw std::runtime_error("Duration model returned invalid frame count");
    metrics[@"rawPredictedLatentFrames"] = @(predictedFrames);
    // Some reference profiles make the duration model predict several seconds
    // for a short greeting. The excess frames can repeat a word or distort its
    // ending. Compare against the same text without speaker conditioning only
    // for short inputs, and retain a modest allowance for a slower speaker.
    // ids has been moved into textInputs. Use the original token count,
    // including BOS, so a long sentence never receives the short-text guard.
    if (!referenceSpeaker_.empty() && length <= 8) {
      Tensors neutralInputs = durationInputs;
      neutralInputs.at("speaker_state") = noRefSpeaker_.at("speaker_state");
      neutralInputs.at("has_speaker") = Tensor::f({1}, {0.f});
      const auto neutralOut = run("duration", neutralInputs);
      const double neutralFrames = std::expm1(
        static_cast<double>(neutralOut.at("log_frames").floats.at(0)));
      if (std::isfinite(neutralFrames) && neutralFrames > 0) {
        metrics[@"neutralPredictedLatentFrames"] = @(neutralFrames);
        if (predictedFrames > neutralFrames * 1.75 &&
            predictedFrames > neutralFrames + 20) {
          predictedFrames = neutralFrames * 1.25;
          metrics[@"shortDurationGuardUsed"] = @1;
        }
      }
    }
    metrics[@"predictedLatentFrames"] = @(predictedFrames);
    metrics[@"durationMs"] = @(elapsedMs(mark));
    metrics[@"durationCapped"] = @(predictedFrames > maxLatentFrames_ + 0.5 ? 1 : 0);
    metrics[@"maxLatentFrames"] = @(maxLatentFrames_);
    if (predictedFrames > maxLatentFrames_ + 0.5) {
      throw std::runtime_error("Irodori sentence exceeds model limit (duration)");
    }
    int64_t frames = std::lround(std::clamp(predictedFrames, 13.0,
                                           static_cast<double>(maxLatentFrames_)));
    if ([[[NSProcessInfo processInfo] arguments]
          containsObject:@"--irodori-benchmark-frames57"]) {
      frames = 57;
    }
    metrics[@"latentFrames"] = @(frames);

    const bool benchmark = [[[NSProcessInfo processInfo] arguments]
      containsObject:@"--irodori-benchmark"];
    const bool benchmarkRandom = [[[NSProcessInfo processInfo] arguments]
      containsObject:@"--irodori-benchmark-random-seed"];
    uint32_t seed;
    if (requestedSeed) {
      const double value = requestedSeed.doubleValue;
      if (!std::isfinite(value) || value < 0 || value > UINT32_MAX || std::floor(value) != value) {
        throw std::runtime_error("Irodori seed must be an integer from 0 through 4294967295");
      }
      seed = static_cast<uint32_t>(value);
    } else {
      seed = (benchmark && !benchmarkRandom) || fixedSeed_ ? 12345u : std::random_device{}();
    }
    // Reproduce a failing sample without changing the normal random policy.
    NSArray<NSString *> *processArguments = [[NSProcessInfo processInfo] arguments];
    const NSUInteger seedIndex = [processArguments indexOfObject:@"--irodori-seed"];
    if (!requestedSeed && seedIndex != NSNotFound && seedIndex + 1 < processArguments.count) {
      NSString *value = processArguments[seedIndex + 1];
      NSScanner *scanner = [NSScanner scannerWithString:value];
      unsigned long long parsed = 0;
      if (![scanner scanUnsignedLongLong:&parsed] || !scanner.isAtEnd || parsed > UINT32_MAX) {
        throw std::runtime_error("Invalid diagnostic Irodori seed");
      }
      seed = static_cast<uint32_t>(parsed);
    }
    // Expose the seed actually used, so a normal app can keep a liked result.
    metrics[@"generationSeed"] = @(seed);
    // Preserve four evaluations; eligible long sentences change only the
    // interval allocation. Other step counts are diagnostic overrides.
    int samplingSteps = 4;
    const NSUInteger stepsIndex = [processArguments indexOfObject:@"--irodori-steps"];
    if (stepsIndex != NSNotFound) {
      if (stepsIndex + 1 >= processArguments.count) {
        throw std::runtime_error("Missing diagnostic Irodori step count");
      }
      NSString *value = processArguments[stepsIndex + 1];
      if (![value isEqualToString:@"4"] && ![value isEqualToString:@"6"] &&
          ![value isEqualToString:@"8"]) {
        throw std::runtime_error("Diagnostic Irodori steps must be 4, 6 or 8");
      }
      samplingSteps = value.intValue;
    }
    metrics[@"samplingSteps"] = @(samplingSteps);
    const bool forceFrontLoaded = [processArguments containsObject:@"--irodori-front-loaded"];
    const bool frontLoaded = forceFrontLoaded ||
      (stepsIndex == NSNotFound && samplingSteps == 4 &&
       IrodoriUseLongSentenceSampling(modelText, frames));
    IrodoriSamplingGrid samplingGrid = frontLoaded ? IrodoriSamplingGrid::frontLoaded
                                                 : IrodoriSamplingGrid::linear;
    const NSUInteger gridIndex = [processArguments indexOfObject:@"--irodori-sampling-grid"];
    if (gridIndex != NSNotFound) {
      if (forceFrontLoaded || gridIndex + 1 >= processArguments.count) {
        throw std::runtime_error("Invalid diagnostic Irodori sampling grid arguments");
      }
      NSString *value = processArguments[gridIndex + 1];
      if ([value isEqualToString:@"linear"]) samplingGrid = IrodoriSamplingGrid::linear;
      else if ([value isEqualToString:@"front"]) samplingGrid = IrodoriSamplingGrid::frontLoaded;
      else throw std::runtime_error("Unknown diagnostic Irodori sampling grid");
    }
    const auto samplingSchedule = IrodoriSamplingSchedule(samplingSteps, samplingGrid);
    metrics[@"frontLoadedSampling"] = @(samplingGrid == IrodoriSamplingGrid::frontLoaded ? 1 : 0);
    metrics[@"samplingGridCode"] = @(static_cast<int>(samplingGrid));
    std::mt19937 random(seed);
    std::normal_distribution<float> normal(0.f, 1.f);
    std::vector<float> latent(frames * 32);
    for (float &v : latent) v = normal(random);
    NSData *initialLatent = benchmark ?
      [NSData dataWithBytes:latent.data() length:latent.size() * sizeof(float)] : nil;
    // Existing converted DiT packages share a text/caption length symbol.
    // Pad projected states (never input tokens) and mask the extra positions.
    // Duration prediction above keeps each condition's original length.
    const int64_t conditioningLength = std::max(length, captionState->shape.at(1));
    auto padState = [&](const Tensor &state) {
      auto padded = state;
      padded.shape[1] = conditioningLength;
      padded.floats.resize(conditioningLength * state.shape[2], 0.f);
      return padded;
    };
    Tensor paddedText, paddedCaption;
    const Tensor *ditText = &textOut.at("text_state");
    const Tensor *ditCaption = captionState;
    if (length < conditioningLength) {
      paddedText = padState(*ditText);
      ditText = &paddedText;
      textMask.resize(conditioningLength, 0.f);
    }
    if (captionState->shape.at(1) < conditioningLength) {
      paddedCaption = padState(*captionState);
      ditCaption = &paddedCaption;
      captionMask.shape[1] = conditioningLength;
      captionMask.floats.resize(conditioningLength, 0.f);
    }
    metrics[@"conditioningTokens"] = @(conditioningLength);
    if (nativeDit_) {
      Tensors context;
      if (nativeDitCached_) {
        mark = Clock::now();
        Tensors contextInputs;
        contextInputs.emplace("text_state", *ditText);
        contextInputs.emplace("speaker_state", speaker);
        contextInputs.emplace("caption_state", *ditCaption);
        context = runContext(contextInputs, metrics);
        metrics[@"contextKvMs"] = @(elapsedMs(mark));
      } else {
        metrics[@"contextKvMs"] = @0;
      }
      mark = Clock::now();
      latent = runNativeDit(std::move(latent), frames,
                            *ditText, Tensor::f({1, conditioningLength}, textMask),
                            speaker, speakerMask, *ditCaption,
                            captionMask, nativeDitCached_ ? &context : nullptr,
                            samplingSchedule, metrics);
      metrics[@"ditFourStepsMs"] = @(elapsedMs(mark));
      metrics[@"ditBackend"] = @"nativeCoreML";
    } else {
      mark = Clock::now();
      Tensors contextInputs;
      contextInputs.emplace("text_state", *ditText);
      contextInputs.emplace("speaker_state", speaker);
      contextInputs.emplace("caption_state", *ditCaption);
      Tensors context = runContext(contextInputs, metrics);
      metrics[@"contextKvMs"] = @(elapsedMs(mark));
      Tensors stepInputs = std::move(context);
      stepInputs.emplace("text_mask", Tensor::f({1, conditioningLength}, textMask));
      stepInputs.emplace("speaker_mask", speakerMask);
      stepInputs.emplace("caption_mask", captionMask);
      stepInputs.emplace("speaker_kv_scales", Tensor::f({12}, std::vector<float>(12, 1.f)));
      stepInputs.emplace("delta_t", Tensor::f({1}, {samplingSchedule.front().delta}));
      stepInputs.emplace("t", Tensor::f({1}, {1.f}));
      stepInputs.emplace("x_t", Tensor::f({1, frames, 32}, latent));
      double ditTotal = 0;
      for (int step = 0; step < samplingSteps; ++step) {
        mark = Clock::now();
        const float samplingDelta = samplingSchedule[step].delta;
        stepInputs.at("t").floats[0] = samplingSchedule[step].time;
        stepInputs.at("delta_t").floats[0] = samplingDelta;
        stepInputs.at("x_t").floats = latent;
        Tensors out = run("dit_step", stepInputs);
        ditTotal += elapsedMs(mark);
        const auto &velocity = out.at("v_pred").floats;
        if (velocity.size() != latent.size()) throw std::runtime_error("DiT shape mismatch");
        for (size_t i = 0; i < latent.size(); ++i) latent[i] -= samplingDelta * velocity[i];
      }
      metrics[@"ditFourStepsMs"] = @(ditTotal);
      metrics[@"ditBackend"] = @"onnxRuntime";
    }
    // Keep the historical timing key for existing benchmark consumers.
    metrics[@"ditSamplingMs"] = metrics[@"ditFourStepsMs"];

    if (std::any_of(latent.begin(), latent.end(),
                    [](float value) { return !std::isfinite(value); })) {
      throw std::runtime_error("DiT produced non-finite latent values");
    }
    NSData *finalLatent = benchmark ?
      [NSData dataWithBytes:latent.data() length:latent.size() * sizeof(float)] : nil;
    mark = Clock::now();
    std::vector<float> wave;
    if (stagedDecoder_) {
      wave = decodeStaged(Tensor::f({1, frames, 32}, std::move(latent)), metrics,
                          onPcm ? &prefix : nullptr);
      metrics[@"decoderBackend"] = @"coreMLStaged2D";
    } else if (nativeDecoder_) {
      wave = decodeNative(Tensor::f({1, frames, 32}, std::move(latent)), metrics);
      metrics[@"decoderBackend"] = @"nativeCoreMLGpu";
    } else if (splitDecoder_) {
      wave = decodeSplit(Tensor::f({1, frames, 32}, std::move(latent)), metrics);
      metrics[@"decoderBackend"] = @"onnxSplit";
    } else {
      Tensors decoderInputs;
      decoderInputs.emplace("latent", Tensor::f({1, frames, 32}, std::move(latent)));
      Tensors decoded = run("dacvae_decode", decoderInputs);
      wave = std::move(decoded.at("waveform").floats);
      metrics[@"decoderBackend"] = @"onnxFull";
    }
    metrics[@"decoderMs"] = @(elapsedMs(mark));
    // Opt-in diagnostics only: distinguish a decoder failure from a playback
    // problem without changing the waveform or normal inference behavior.
    if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--irodori-audio-health"]) {
      size_t nonFinite = 0, clipped = 0;
      double peak = 0, energy = 0;
      for (float value : wave) {
        if (!std::isfinite(value)) { ++nonFinite; continue; }
        peak = std::max(peak, std::abs(static_cast<double>(value)));
        energy += static_cast<double>(value) * value;
        if (std::abs(value) >= 1.f) ++clipped;
      }
      metrics[@"rawWaveNonFiniteSamples"] = @(nonFinite);
      metrics[@"rawWaveClippedSamples"] = @(clipped);
      metrics[@"rawWavePeak"] = @(peak);
      metrics[@"rawWaveRms"] = @(wave.empty() ? 0 : std::sqrt(energy / wave.size()));
    }
    // The decoder may place almost a second of silence at both ends of a
    // sentence. Keep a small lead and sentence gap so playback can start the
    // next prepared segment promptly without clipping soft consonants.
    constexpr size_t blockSamples = 960; // 20 ms at 48 kHz.
    size_t firstActive = wave.size();
    size_t lastActiveEnd = 0;
    std::vector<size_t> activeBlocks;
    std::vector<double> blockRms;
    for (size_t begin = 0; begin < wave.size(); begin += blockSamples) {
      const size_t end = std::min(begin + blockSamples, wave.size());
      double energy = 0;
      for (size_t i = begin; i < end; ++i) {
        const double value = std::isfinite(wave[i]) ? wave[i] : 0;
        energy += value * value;
      }
      const double rms = std::sqrt(energy / (end - begin));
      blockRms.push_back(rms);
      if (rms > 0.002) {
        firstActive = std::min(firstActive, begin);
        lastActiveEnd = end;
        activeBlocks.push_back(begin / blockSamples);
      }
    }
    // A quiet, short burst after a long silent tail is a decoder artifact,
    // not another word. Without this check the burst keeps over a second of
    // silence and the noise itself in the spoken segment.
    if (activeBlocks.size() > 1) {
      size_t islandStart = activeBlocks.size() - 1;
      while (islandStart > 0 &&
             activeBlocks[islandStart] - activeBlocks[islandStart - 1] <= 7) {
        --islandStart;
      }
      if (islandStart > 0) {
        const size_t previousEnd = std::min(
          wave.size(), (activeBlocks[islandStart - 1] + 1) * blockSamples);
        const size_t finalStart = activeBlocks[islandStart] * blockSamples;
        const size_t finalSpan = activeBlocks.back() - activeBlocks[islandStart] + 1;
        const size_t activeCount = activeBlocks.size() - islandStart;
        double peakRms = 0;
        for (size_t i = islandStart; i < activeBlocks.size(); ++i) {
          peakRms = std::max(peakRms, blockRms[activeBlocks[i]]);
        }
        if (finalStart >= previousEnd + 28800 && // At least 600 ms silence.
            finalSpan <= 12 && activeCount <= 5 && peakRms < 0.04) {
          metrics[@"discardedTailArtifactMs"] =
            @((lastActiveEnd - previousEnd) / 48.0);
          lastActiveEnd = previousEnd;
        }
      }
    }
    const size_t audioStart = firstActive == wave.size() ? 0 :
      (firstActive > 5760 ? firstActive - 5760 : 0); // 120 ms lead.
    const size_t audioEnd = lastActiveEnd == 0 ? wave.size() :
      std::min(wave.size(), lastActiveEnd + 1920); // Up to 40 ms decay.
    constexpr size_t endingGap = 5760; // 120 ms additional pause.
    std::vector<int16_t> pcm(audioEnd - audioStart + endingGap, 0);
    for (size_t i = audioStart; i < audioEnd; ++i) {
      float value = std::clamp(std::isfinite(wave[i]) ? wave[i] : 0.f, -1.f, 1.f);
      pcm[i - audioStart] = static_cast<int16_t>(std::lrint(value * 32767.f));
    }
    metrics[@"incrementalEarlySamples"] = @(prefix.emittedSamples());
    prefix.finish(pcm);
    metrics[@"incrementalChunkCount"] = @(chunkCount);
    metrics[@"incrementalSamples"] = @(streamedSamples);
    metrics[@"trimmedLeadingMs"] = @(audioStart / 48.0);
    metrics[@"trimmedTrailingMs"] = @((wave.size() - audioEnd) / 48.0);
    metrics[@"rawSamples"] = @(wave.size());
    metrics[@"endingGapMs"] = @(endingGap / 48.0);
    metrics[@"samples"] = @(pcm.size());
    metrics[@"thermalState"] = @([[NSProcessInfo processInfo] thermalState]);
    metrics[@"lowPowerMode"] = @([[NSProcessInfo processInfo] isLowPowerModeEnabled] ? 1 : 0);
    metrics[@"coreMlRequested"] = @(useCoreML_ ? 1 : 0);
    metrics[@"onnxThreads"] = @(onnxThreads_);
    metrics[@"onnxAllowSpinning"] = @(onnxAllowSpinning_ ? 1 : 0);
    metrics[@"textEncoderQuantized"] = @(quantizedTextEncoder_ ? 1 : 0);
    metrics[@"nativeDitUsed"] = @(nativeDit_ ? 1 : 0);
    metrics[@"ditNeAllowed"] = @(nativeDitNeAllowed_ ? 1 : 0);
    metrics[@"ditMixedMlpUsed"] = @([nativeDitPrecision_ isEqualToString:@"mixed-mlp"] ? 1 : 0);
    metrics[@"ditMixedLinearUsed"] = @([nativeDitPrecision_ isEqualToString:@"mixed-linear"] ? 1 : 0);
    metrics[@"nativeDitCachedUsed"] = @(nativeDitCached_ ? 1 : 0);
    metrics[@"nativeDitPrecision"] = nativeDit_ ? nativeDitPrecision_ : @"none";
    metrics[@"coreMlStagedDecoderUsed"] = @(stagedDecoder_ ? 1 : 0);
    metrics[@"nativeDecoderUsed"] = @(nativeDecoder_ ? 1 : 0);
    metrics[@"splitDecoderUsed"] = @(!stagedDecoder_ && !nativeDecoder_ && splitDecoder_ ? 1 : 0);
    NSData *data = [NSData dataWithBytes:pcm.data() length:pcm.size() * sizeof(int16_t)];
    NSMutableDictionary *result = [@{@"pcm16": data, @"sampleRate": @48000,
                                    @"metrics": metrics} mutableCopy];
    if (benchmark || profileInference_) {
      unsigned char pcmDigest[CC_SHA256_DIGEST_LENGTH];
      CC_SHA256(pcm.data(), static_cast<CC_LONG>(pcm.size() * sizeof(int16_t)), pcmDigest);
      NSMutableString *pcmHash = [NSMutableString stringWithCapacity:64];
      for (unsigned char byte : pcmDigest) [pcmHash appendFormat:@"%02x", byte];
      metrics[@"pcmSha256"] = pcmHash;
    }
    if (benchmark) {
      result[@"rawWaveF32"] = [NSData dataWithBytes:wave.data()
        length:wave.size() * sizeof(float)];
      result[@"initialLatentF32"] = initialLatent;
      result[@"finalLatentF32"] = finalLatent;
      result[@"textStateF32"] = [NSData dataWithBytes:textOut.at("text_state").floats.data()
        length:textOut.at("text_state").floats.size() * sizeof(float)];
      result[@"captionStateF32"] = [NSData dataWithBytes:captionState->floats.data()
        length:captionState->floats.size() * sizeof(float)];
      result[@"speakerStateF32"] = [NSData dataWithBytes:speaker.floats.data()
        length:speaker.floats.size() * sizeof(float)];
      if (!debugDitStep0_.empty()) {
        result[@"step0LatentF32"] = [NSData dataWithBytes:debugDitStep0_.data()
          length:debugDitStep0_.size() * sizeof(float)];
      }
    }
    metrics[@"nativeSynthesisMs"] = @(elapsedMs(synthesisStarted));
    metrics[@"trimAuxiliarySessions"] = @(trimAuxiliarySessions_ ? 1 : 0);
    metrics[@"speakerContextSessionResident"] = @(sessions_.count("context_kv_speaker"));
    metrics[@"speakerContextSessionLoads"] = @(sessionLoadCounts_["context_kv_speaker"]);
    metrics[@"decoderStage1OnnxResident"] = @(sessions_.count("decoder_stage_1"));
    metrics[@"decoderStage1OnnxLoads"] = @(sessionLoadCounts_["decoder_stage_1"]);
    metrics[@"auxiliaryHeapReleasedMiB"] = @(auxiliaryHeapReleasedBytes_ / (1024.0 * 1024.0));
    metrics[@"auxiliaryHeapReliefMs"] = @(auxiliaryHeapReliefMs_);
    if (profileInference_) metrics[@"physicalFootprintEndMiB"] = @(physicalFootprintMiB());
    return result;
  }

 private:
  Tensors runContext(const Tensors &inputs, NSMutableDictionary *metrics) {
    metrics[@"contextSplitUsed"] = @(splitContext_ ? 1 : 0);
    if (!splitContext_) return run("context_kv", inputs);
    Tensors context = run("context_kv_text", inputs);
    Tensors speaker;
    const bool hit = !cachedSpeakerContext_.empty();
    if (hit) {
      speaker = cachedSpeakerContext_;
    } else {
      // A voice change invalidates only the cached features. Reload the same
      // projection model once, then keep its owned output tensors, not weights.
      loadOnnxSession("context_kv_speaker");
      speaker = run("context_kv_speaker", inputs);
      size_t bytes = 0;
      for (const auto &entry : speaker) bytes += entry.second.floats.size() * sizeof(float);
      // Bound extra residency even for the supported 120-second reference.
      // Large references still use exact split inference, without a cache.
      if (bytes <= 16 * 1024 * 1024) {
        cachedSpeakerContext_ = speaker;
        cachedSpeakerContextBytes_ = bytes;
        if (trimAuxiliarySessions_) {
          sessions_.erase("context_kv_speaker");
          releaseUnusedHeap();
        }
      }
    }
    context.merge(speaker);
    metrics[@"contextSpeakerCacheHit"] = @(hit ? 1 : 0);
    metrics[@"contextSpeakerCacheBytes"] = @(cachedSpeakerContextBytes_);
    return context;
  }

  MLMultiArray *coreMLArray(const Tensor &tensor) {
    if (tensor.integers.size() || tensor.shape.empty() || tensor.shape.size() > 4) {
      throw std::runtime_error("Invalid Core ML input tensor");
    }
    NSMutableArray<NSNumber *> *shape = [NSMutableArray arrayWithCapacity:tensor.shape.size()];
    size_t expected = 1;
    for (int64_t dimension : tensor.shape) {
      if (dimension <= 0) throw std::runtime_error("Invalid Core ML input shape");
      expected *= static_cast<size_t>(dimension);
      [shape addObject:@(dimension)];
    }
    if (expected != tensor.floats.size()) throw std::runtime_error("Core ML input size mismatch");
    NSError *error = nil;
    const MLMultiArrayDataType dataType = nativeDitDataType_;
    MLMultiArray *result = [[MLMultiArray alloc] initWithShape:shape
      dataType:dataType error:&error];
    if (!result) throw std::runtime_error("Could not allocate Core ML tensor");
    const bool useHalf = dataType != MLMultiArrayDataTypeFloat32;
    __fp16 *halfDestination = useHalf ? static_cast<__fp16 *>(result.dataPointer) : nullptr;
    float *floatDestination = useHalf ? nullptr : static_cast<float *>(result.dataPointer);
    size_t contiguousStride = 1;
    bool contiguous = true;
    for (size_t dim = tensor.shape.size(); dim > 0; --dim) {
      const size_t index = dim - 1;
      contiguous &= result.strides[index].unsignedLongLongValue == contiguousStride;
      contiguousStride *= static_cast<size_t>(tensor.shape[index]);
    }
    if (contiguous) {
      if (useHalf) {
        for (size_t flat = 0; flat < expected; ++flat) {
          const __fp16 value = static_cast<__fp16>(tensor.floats[flat]);
          if (!std::isfinite(static_cast<float>(value))) {
            throw std::runtime_error("Core ML DiT input overflowed Float16");
          }
          halfDestination[flat] = value;
        }
      } else {
        std::memcpy(floatDestination, tensor.floats.data(), expected * sizeof(float));
      }
      return result;
    }
    for (size_t flat = 0; flat < expected; ++flat) {
      size_t remaining = flat;
      int64_t offset = 0;
      for (size_t dim = tensor.shape.size(); dim > 0; --dim) {
        const size_t index = dim - 1;
        offset += static_cast<int64_t>(remaining % tensor.shape[index]) *
                  result.strides[index].longLongValue;
        remaining /= static_cast<size_t>(tensor.shape[index]);
      }
      if (useHalf) {
        const __fp16 value = static_cast<__fp16>(tensor.floats[flat]);
        if (!std::isfinite(static_cast<float>(value))) {
          throw std::runtime_error("Core ML DiT input overflowed Float16");
        }
        halfDestination[offset] = value;
      } else {
        floatDestination[offset] = tensor.floats[flat];
      }
    }
    return result;
  }

  std::vector<float> runNativeDit(std::vector<float> latent, int64_t frames,
                                  const Tensor &text, const Tensor &textMask,
                                  const Tensor &speaker, const Tensor &speakerMask,
                                  const Tensor &caption, const Tensor &captionMask,
                                  const Tensors *context,
                                  const std::vector<IrodoriSamplingStep> &samplingSchedule,
                                  NSMutableDictionary *metrics) {
    const MLMultiArrayDataType expectedDataType = nativeDitDataType_;
    if (frames < 13 || frames > maxLatentFrames_ || text.shape.size() != 3 ||
        speaker.shape.size() != 3 || caption.shape.size() != 3 ||
        text.shape[1] < 1 || text.shape[1] > maxTextTokens_ ||
        speaker.shape[1] < 1 || speaker.shape[1] > 751 ||
        caption.shape[1] != text.shape[1]) {
      throw std::runtime_error("Core ML DiT input shape is outside converted range");
    }
    float inputMaxAbs = 0.f;
    auto checkFinite = [&](const Tensor &tensor, const char *name) {
      for (float value : tensor.floats) {
        if (!std::isfinite(value)) {
          throw std::runtime_error(std::string("Non-finite Core ML DiT input: ") + name);
        }
        inputMaxAbs = std::max(inputMaxAbs, std::abs(value));
      }
    };
    checkFinite(text, "text_state");
    checkFinite(speaker, "speaker_state");
    checkFinite(caption, "caption_state");
    if (context) {
      for (const auto &entry : *context) checkFinite(entry.second, entry.first.c_str());
    }
    metrics[@"ditInputMaxAbs"] = @(inputMaxAbs);
    auto setupStarted = Clock::now();
    NSMutableDictionary<NSString *, MLFeatureValue *> *values = [NSMutableDictionary dictionary];
    Tensor deltaInput = Tensor::f({1}, {samplingSchedule.front().delta});
    Tensor timeInput = Tensor::f({1}, {1.f});
    Tensor latentInput = Tensor::f({1, frames, 32}, std::move(latent));
    values[@"delta_t"] = [MLFeatureValue featureValueWithMultiArray:
      coreMLArray(deltaInput)];
    for (const auto &item : std::vector<std::pair<NSString *, const Tensor *>>{
           {@"text_state", &text}, {@"text_mask", &textMask},
           {@"speaker_state", &speaker}, {@"speaker_mask", &speakerMask},
           {@"caption_state", &caption}, {@"caption_mask", &captionMask}}) {
      values[item.first] = [MLFeatureValue featureValueWithMultiArray:
        coreMLArray(*item.second)];
    }
    if (context) {
      for (int layer = 0; layer < 12; ++layer) {
        for (const char *kind : {"text", "speaker", "caption"}) {
          for (const char *part : {"k", "v"}) {
            const std::string name = std::string(kind) + "_" + part + "_" + std::to_string(layer);
            NSString *key = [NSString stringWithUTF8String:name.c_str()];
            values[key] = [MLFeatureValue featureValueWithMultiArray:
              coreMLArray(context->at(name))];
          }
        }
      }
    }
    metrics[@"nativeDitSetupMs"] = @(elapsedMs(setupStarted));
    for (int step = 0; step < samplingSchedule.size(); ++step) {
      auto started = Clock::now();
      const float delta = samplingSchedule[step].delta;
      if (profileInference_) {
        metrics[[NSString stringWithFormat:@"nativeDitStep%dFootprintBeforeMiB", step]] =
          @(physicalFootprintMiB());
      }
      withInferencePool(innerPools_, [&] {
        timeInput.floats[0] = samplingSchedule[step].time;
        deltaInput.floats[0] = delta;
        values[@"delta_t"] = [MLFeatureValue featureValueWithMultiArray:coreMLArray(deltaInput)];
        values[@"t"] = [MLFeatureValue featureValueWithMultiArray:coreMLArray(timeInput)];
        values[@"x_t"] = [MLFeatureValue featureValueWithMultiArray:coreMLArray(latentInput)];
        NSError *error = nil;
        MLDictionaryFeatureProvider *features = [[MLDictionaryFeatureProvider alloc]
          initWithDictionary:values error:&error];
        if (!features) throw std::runtime_error("Could not create Core ML DiT features");
        const auto predictionStarted = Clock::now();
        id<MLFeatureProvider> result = [nativeDit_ predictionFromFeatures:features error:&error];
        metrics[[NSString stringWithFormat:@"nativeDitStep%dPredictionMs", step]] =
          @(elapsedMs(predictionStarted));
        if (!result) throw std::runtime_error("Native Core ML DiT prediction failed");
        MLMultiArray *velocity = [result featureValueForName:@"v_pred"].multiArrayValue;
        if (!velocity || velocity.dataType != expectedDataType ||
            velocity.shape.count != 3 || velocity.shape[1].longLongValue != frames ||
            velocity.shape[2].longLongValue != 32) {
          throw std::runtime_error("Invalid native Core ML DiT output");
        }
        const bool useHalf = expectedDataType != MLMultiArrayDataTypeFloat32;
        const __fp16 *halfSource = useHalf ? static_cast<const __fp16 *>(velocity.dataPointer) : nullptr;
        const float *floatSource = useHalf ? nullptr : static_cast<const float *>(velocity.dataPointer);
        const int64_t timeStride = velocity.strides[1].longLongValue;
        const int64_t channelStride = velocity.strides[2].longLongValue;
        for (int64_t time = 0; time < frames; ++time) {
          for (int64_t channel = 0; channel < 32; ++channel) {
            const size_t index = static_cast<size_t>(time * 32 + channel);
            const int64_t offset = time * timeStride + channel * channelStride;
            const float value = useHalf ? static_cast<float>(halfSource[offset])
                                        : floatSource[offset];
            if (!std::isfinite(value)) {
              throw std::runtime_error("Core ML DiT produced non-finite velocity at step " +
                std::to_string(step));
            }
            latentInput.floats[index] -= delta * value;
          }
        }
      });
      metrics[[NSString stringWithFormat:@"nativeDitStep%dMs", step]] = @(elapsedMs(started));
      if (profileInference_) {
        metrics[[NSString stringWithFormat:@"nativeDitStep%dFootprintAfterMiB", step]] =
          @(physicalFootprintMiB());
      }
      if (step == 0 && [[[NSProcessInfo processInfo] arguments]
                        containsObject:@"--irodori-benchmark"]) {
        debugDitStep0_ = latentInput.floats;
      }
    }
    return std::move(latentInput.floats);
  }

  std::vector<float> decodeNative(Tensor latent, NSMutableDictionary *metrics) {
    const int64_t frames = latent.shape.at(1);
    if (frames < 1 || frames > 64 || latent.floats.size() != static_cast<size_t>(frames * 32)) {
      throw std::runtime_error("Invalid native decoder latent shape");
    }
    // The supplied Core ML decoder accepts at most 42 latent frames. A cut at
    // frame 33 leaves at least nine frames of context on both sides for 43-64.
    struct Window { int64_t start, length, outputStart, outputEnd; };
    std::vector<Window> windows = frames <= 42
      ? std::vector<Window>{{0, frames, 0, frames}}
      : std::vector<Window>{{0, 42, 0, 33}, {24, frames - 24, 33, frames}};
    std::vector<float> audio(frames * 1920);
    for (const Window &window : windows) {
      NSError *error = nil;
      MLMultiArray *input = [[MLMultiArray alloc]
        initWithShape:@[@1, @(window.length), @32]
             dataType:MLMultiArrayDataTypeFloat32 error:&error];
      if (!input) throw std::runtime_error("Could not allocate native decoder input");
      float *destination = static_cast<float *>(input.dataPointer);
      const int64_t step1 = input.strides[1].longLongValue;
      const int64_t step2 = input.strides[2].longLongValue;
      for (int64_t t = 0; t < window.length; ++t) {
        for (int64_t channel = 0; channel < 32; ++channel) {
          destination[t * step1 + channel * step2] =
            latent.floats[(window.start + t) * 32 + channel];
        }
      }
      MLDictionaryFeatureProvider *features = [[MLDictionaryFeatureProvider alloc]
        initWithDictionary:@{@"latent": [MLFeatureValue featureValueWithMultiArray:input]}
                  error:&error];
      if (!features) throw std::runtime_error("Could not create native decoder features");
      id<MLFeatureProvider> result = [nativeDecoder_ predictionFromFeatures:features error:&error];
      if (!result) {
        throw std::runtime_error("Native Core ML decoder prediction failed");
      }
      MLMultiArray *output = [result featureValueForName:@"waveform"].multiArrayValue;
      if (!output || output.dataType != MLMultiArrayDataTypeFloat32 ||
          output.shape.count != 3 || output.shape[2].longLongValue != window.length * 1920) {
        throw std::runtime_error("Invalid native Core ML decoder output");
      }
      const float *source = static_cast<const float *>(output.dataPointer);
      const int64_t outputStep = output.strides[2].longLongValue;
      for (int64_t frame = window.outputStart; frame < window.outputEnd; ++frame) {
        const int64_t sourceOffset = (frame - window.start) * 1920;
        const int64_t targetOffset = frame * 1920;
        for (int64_t sample = 0; sample < 1920; ++sample) {
          audio[targetOffset + sample] = source[(sourceOffset + sample) * outputStep];
        }
      }
    }
    metrics[@"nativeDecoderWindows"] = @(windows.size());
    return audio;
  }

  Tensor runStagedCoreML(int stage, const Tensor &input,
                         MLModel *alternateModel = nil) {
    return withInferencePool(innerPools_, [&] {
      return runStagedCoreMLImpl(stage, input, alternateModel);
    });
  }

  Tensor runStagedCoreMLImpl(int stage, const Tensor &input, MLModel *alternateModel) {
    auto copyStarted = Clock::now();
    const int64_t inputChannels = stage == 1 ? 1536 : stage == 2 ? 768 : 384;
    const int64_t outputChannels = stage == 1 ? 768 : stage == 2 ? 384 : 1;
    const int64_t scale = stage == 1 ? 12 : stage == 2 ? 10 : 16;
    if (stage < 1 || stage > 3 || input.shape.size() != 3 ||
        input.shape[0] != 1 || input.shape[1] != inputChannels ||
        input.floats.size() != static_cast<size_t>(inputChannels * input.shape[2])) {
      throw std::runtime_error("Invalid 2D Core ML decoder stage input");
    }
    MLModel *model = alternateModel ?: stagedDecoderModels_[stage - 1];
    if (!model) throw std::runtime_error("2D Core ML decoder stage is unavailable");
    const int64_t width = input.shape[2];
    MLMultiArrayDataType dataType = model.modelDescription.inputDescriptionsByName
      [@"stage_input"].multiArrayConstraint.dataType;
    bool half = false;
    if (@available(iOS 16.0, *)) half = dataType == MLMultiArrayDataTypeFloat16;
    if (!half && dataType != MLMultiArrayDataTypeFloat32) {
      throw std::runtime_error("Unsupported 2D Core ML decoder input type");
    }
    NSError *error = nil;
    MLMultiArray *array = [[MLMultiArray alloc]
      initWithShape:@[@1, @(inputChannels), @1, @(width)]
           dataType:dataType error:&error];
    if (!array) throw std::runtime_error("Could not allocate 2D Core ML decoder input");
    const int64_t channelStride = array.strides[1].longLongValue;
    const int64_t timeStride = array.strides[3].longLongValue;
    __fp16 *halfBuffer = half ? static_cast<__fp16 *>(array.dataPointer) : nullptr;
    float *floatBuffer = half ? nullptr : static_cast<float *>(array.dataPointer);
    for (int64_t channel = 0; channel < inputChannels; ++channel) {
      for (int64_t time = 0; time < width; ++time) {
        const size_t source = static_cast<size_t>(channel * width + time);
        const int64_t target = channel * channelStride + time * timeStride;
        if (half) halfBuffer[target] = static_cast<__fp16>(input.floats[source]);
        else floatBuffer[target] = input.floats[source];
      }
    }
    MLDictionaryFeatureProvider *features = [[MLDictionaryFeatureProvider alloc]
      initWithDictionary:@{@"stage_input": [MLFeatureValue featureValueWithMultiArray:array]}
                error:&error];
    if (!features) {
      throw std::runtime_error("Could not create 2D Core ML decoder features for stage " +
        std::to_string(stage) + ": " + (error ? error.localizedDescription.UTF8String : "unknown"));
    }
    recordDecoderPhase(stage, 0, copyStarted);
    const auto predictionStarted = Clock::now();
    id<MLFeatureProvider> result = [model predictionFromFeatures:features error:&error];
    if (!result && !alternateModel) {
      NSLog(@"Irodori 2D Core ML decoder stage %d mode %d failed: %@", stage,
            stagedDecoderModes_[stage - 1], error);
      for (int mode = stagedDecoderModes_[stage - 1] + 1; mode <= 2; ++mode) {
        MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
        configuration.computeUnits = mode == 1 ? MLComputeUnitsCPUAndGPU : MLComputeUnitsCPUOnly;
        NSError *fallbackError = nil;
        MLModel *fallback = [MLModel modelWithContentsOfURL:
          stagedDecoderCompiledUrls_[stage - 1] configuration:configuration
                                             error:&fallbackError];
        if (fallback) {
          result = [fallback predictionFromFeatures:features error:&fallbackError];
        }
        if (result) {
          stagedDecoderModels_[stage - 1] = fallback;
          stagedDecoderModes_[stage - 1] = mode;
          NSLog(@"Irodori 2D Core ML decoder stage %d using fallback mode %d", stage,
                mode);
          break;
        }
        NSLog(@"Irodori 2D Core ML decoder stage %d fallback mode %d failed: %@",
              stage, mode, fallbackError);
        error = fallbackError;
      }
    }
    if (!result) {
      throw std::runtime_error("2D Core ML decoder stage " + std::to_string(stage) +
        " prediction failed: " + (error ? error.description.UTF8String : "unknown"));
    }
    recordDecoderPhase(stage, 1, predictionStarted);
    copyStarted = Clock::now();
    MLMultiArray *output = [result featureValueForName:@"stage_output"].multiArrayValue;
    bool outputHalf = false;
    if (@available(iOS 16.0, *)) {
      outputHalf = output && output.dataType == MLMultiArrayDataTypeFloat16;
    }
    if (!output || output.shape.count != 4 || output.shape[0].longLongValue != 1 ||
        output.shape[1].longLongValue != outputChannels ||
        output.shape[2].longLongValue != 1 ||
        output.shape[3].longLongValue != width * scale ||
        (!outputHalf && output.dataType != MLMultiArrayDataTypeFloat32)) {
      throw std::runtime_error("Unexpected 2D Core ML decoder output");
    }
    const __fp16 *halfSource = outputHalf ?
      static_cast<const __fp16 *>(output.dataPointer) : nullptr;
    const float *floatSource = outputHalf ?
      nullptr : static_cast<const float *>(output.dataPointer);
    const int64_t outChannelStride = output.strides[1].longLongValue;
    const int64_t outTimeStride = output.strides[3].longLongValue;
    std::vector<float> values(static_cast<size_t>(outputChannels * width * scale));
    for (int64_t channel = 0; channel < outputChannels; ++channel) {
      for (int64_t time = 0; time < width * scale; ++time) {
        const int64_t offset = channel * outChannelStride + time * outTimeStride;
        values[static_cast<size_t>(channel * width * scale + time)] = outputHalf ?
          static_cast<float>(halfSource[offset]) : floatSource[offset];
      }
    }
    recordDecoderPhase(stage, 2, copyStarted);
    return Tensor::f({1, outputChannels, width * scale}, std::move(values));
  }

  void recordDecoderPhase(int stage, int phase, Clock::time_point started) {
    if (!profileInference_) return;
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
      Clock::now() - started).count();
    // Stage 3 has two independent prediction lanes. These totals include both
    // lanes, so they are accumulated work time rather than parallel wall time.
    decoderPhaseNanos_[(stage - 1) * 3 + phase].fetch_add(elapsed, std::memory_order_relaxed);
  }

  std::vector<float> decodeStaged(Tensor latent, NSMutableDictionary *metrics,
                                IrodoriPcmPrefix *prefix = nullptr) {
    for (auto &value : decoderPhaseNanos_) value.store(0, std::memory_order_relaxed);
    const bool debugStats = [[[NSProcessInfo processInfo] arguments]
      containsObject:@"--irodori-benchmark"] || [[[NSProcessInfo processInfo] arguments]
      containsObject:@"--irodori-audio-health"];
    auto recordStats = [&](const Tensor &tensor, int stage) {
      if (!debugStats) return;
      float minimum = std::numeric_limits<float>::infinity();
      float maximum = -std::numeric_limits<float>::infinity();
      size_t nonFinite = 0;
      for (float value : tensor.floats) {
        if (!std::isfinite(value)) { ++nonFinite; continue; }
        minimum = std::min(minimum, value);
        maximum = std::max(maximum, value);
      }
      if (nonFinite == tensor.floats.size()) { minimum = 0.f; maximum = 0.f; }
      NSString *prefix = [NSString stringWithFormat:@"decoderStage%d", stage];
      metrics[[prefix stringByAppendingString:@"Min"]] = @(minimum);
      metrics[[prefix stringByAppendingString:@"Max"]] = @(maximum);
      metrics[[prefix stringByAppendingString:@"NonFinite"]] = @(nonFinite);
    };
    auto started = Clock::now();
    Tensors stageZero = run("decoder_stage_0", {{"latent", std::move(latent)}});
    Tensor current = std::move(stageZero.at("/decoder/model.0/Conv_output_0"));
    metrics[@"decoderStage0Ms"] = @(elapsedMs(started));
    recordStats(current, 0);
    started = Clock::now();
    int stage1Mode = stagedDecoderModes_[0];
    bool usedEnumerated = false;
    bool usedTiled = false;
    auto runFlexibleStage1 = [&]() {
      const bool forceOnnx = [[[NSProcessInfo processInfo] arguments]
        containsObject:@"--irodori-stage1-onnx"];
      if (stagedDecoderStage1Flexible_ && !forceOnnx) {
        try {
          current = runStagedCoreML(1, current, stagedDecoderStage1Flexible_);
          stage1Mode = 1;
          return;
        } catch (const std::exception &e) {
          if (!stage1OnnxFallbackAvailable_) throw;
          NSLog(@"Irodori flexible stage 1 failed, using ONNX: %s", e.what());
        }
      }
      loadOnnxSession("decoder_stage_1");
      Tensors stageOne = run("decoder_stage_1",
        {{"/decoder/model.0/Conv_output_0", std::move(current)}});
      current = std::move(stageOne.at("/decoder/model.1/block.8/Add_output_0"));
      stage1Mode = 3;
    };
    if (stagedDecoderStage1Enumerated_ &&
        stagedDecoderStage1EnumeratedWidths_.count(current.shape[2])) {
      try {
        current = runStagedCoreML(1, current, stagedDecoderStage1Enumerated_);
        stage1Mode = 0;
        usedEnumerated = true;
      } catch (const std::exception &e) {
        NSLog(@"Irodori enumerated stage 1 failed: %s", e.what());
      }
    }
    if (usedEnumerated) {
      // The exact input shape has its own compiled Core ML plan.
    } else if (stagedDecoderFixed_[0] && current.shape[2] > 64 &&
               ![[[NSProcessInfo processInfo] arguments]
                 containsObject:@"--irodori-stage1-flexible"] &&
               ![[[NSProcessInfo processInfo] arguments]
                 containsObject:@"--irodori-stage1-onnx"]) {
      try {
        if (current.shape[1] != 1536) {
          throw std::runtime_error("Unexpected stage 1 input channels");
        }
        constexpr int64_t width = 64;
        constexpr int64_t context = 5;
        constexpr int64_t step = width - 2 * context;
        constexpr int64_t scale = 12;
        constexpr int64_t inputChannels = 1536;
        constexpr int64_t outputChannels = 768;
        const int64_t total = current.shape[2];
        std::vector<float> output(static_cast<size_t>(outputChannels * total * scale));
        int windows = 0;
        for (int64_t start = 0; start < total; start += step) {
          // Keep the final window aligned with the end of the utterance.
          // Padding its input with zeros changes the final decoder samples.
          const int64_t left = std::max<int64_t>(
            0, std::min<int64_t>(start - context, total - width));
          const int64_t right = left + width;
          const int64_t length = right - left;
          std::vector<float> samples(static_cast<size_t>(inputChannels * width));
          for (int64_t channel = 0; channel < inputChannels; ++channel) {
            const float *begin = current.floats.data() + channel * total + left;
            std::copy(begin, begin + length, samples.data() + channel * width);
          }
          Tensor decoded = runStagedCoreML(1,
            Tensor::f({1, inputChannels, width}, std::move(samples)));
          const int64_t count = std::min<int64_t>(step, total - start) * scale;
          const int64_t crop = (start - left) * scale;
          for (int64_t channel = 0; channel < outputChannels; ++channel) {
            const float *begin = decoded.floats.data() +
              channel * width * scale + crop;
            std::copy(begin, begin + count,
                      output.data() + channel * total * scale + start * scale);
          }
          ++windows;
        }
        current = Tensor::f({1, outputChannels, total * scale}, std::move(output));
        metrics[@"decoderStage1Windows"] = @(windows);
        stage1Mode = 0;
        usedTiled = true;
      } catch (const std::exception &e) {
        NSLog(@"Irodori tiled stage 1 failed, using flexible model: %s", e.what());
        runFlexibleStage1();
      }
    } else if (stagedDecoderFixed_[0] && current.shape[2] == 57 &&
        stagedDecoderStage1Fixed57_) {
      current = runStagedCoreML(1, current, stagedDecoderStage1Fixed57_);
      stage1Mode = 0;
    } else if (stagedDecoderFixed_[0] && current.shape[2] != 64) {
      runFlexibleStage1();
    } else {
      current = runStagedCoreML(1, current);
    }
    metrics[@"decoderStage1Ms"] = @(elapsedMs(started));
    metrics[@"decoderStage1EnumeratedUsed"] = @(usedEnumerated ? 1 : 0);
    metrics[@"decoderStage1TiledUsed"] = @(usedTiled ? 1 : 0);
    recordStats(current, 1);

    auto tiled = [&](const Tensor &source, int stage, int width, int context,
                     int scale, int channels) -> Tensor {
      if (source.shape.size() != 3 || source.shape[0] != 1) {
        throw std::runtime_error("Unexpected 2D Core ML decoder source shape");
      }
      const int64_t total = source.shape[2];
      const int64_t inputChannels = source.shape[1];
      const int64_t step = width - context * 2;
      const bool fixedStage3All = stage == 3 &&
        [[[NSProcessInfo processInfo] arguments]
          containsObject:@"--irodori-stage3-fixed-windows"];
      const bool fixedStage3First = stage == 3 &&
        ![[[NSProcessInfo processInfo] arguments]
          containsObject:@"--irodori-stage3-flexible"];
      std::vector<float> output(static_cast<size_t>(channels * total * scale));
      int windows = 0;
      int fixedWindows = 0;
      const int64_t windowCount = (total + step - 1) / step;
      std::mutex prefixMutex;
      std::vector<bool> completed(static_cast<size_t>(windowCount), false);
      int64_t completedPrefix = 0;
      auto processWindow = [&](int64_t index, MLModel *model) -> bool {
        const int64_t start = index * step;
        const int64_t left = std::max<int64_t>(0, start - context);
        const int64_t right = std::min<int64_t>(total, start + step + context);
        const int64_t length = right - left;
        const bool fixedStage3 = fixedStage3All ||
          (fixedStage3First && right < total);
        const int64_t inferenceLength =
          fixedStage3 || (stage == 2 && stagedDecoderFixed_[1]) ? width : length;
        // A padded final window must end at the true utterance boundary.
        // Left alignment preserves the first window; right alignment preserves
        // the last. The overlap crop removes the opposite padded boundary.
        const int64_t padLeft = fixedStage3 && right == total && start > 0 ?
          width - length : 0;
        std::vector<float> samples(static_cast<size_t>(inputChannels * inferenceLength));
        for (int64_t channel = 0; channel < inputChannels; ++channel) {
          const float *begin = source.floats.data() + channel * total + left;
          std::copy(begin, begin + length,
                    samples.data() + channel * inferenceLength + padLeft);
        }
        Tensor decoded = runStagedCoreML(stage,
          Tensor::f({1, inputChannels, inferenceLength}, std::move(samples)), model);
        const int64_t count = std::min<int64_t>(step, total - start) * scale;
        const int64_t crop = (start - left + padLeft) * scale;
        for (int64_t channel = 0; channel < channels; ++channel) {
          const float *begin = decoded.floats.data() +
            channel * inferenceLength * scale + crop;
          std::copy(begin, begin + count,
                    output.data() + channel * total * scale + start * scale);
        }
        if (stage == 3 && prefix) {
          std::lock_guard<std::mutex> lock(prefixMutex);
          completed[static_cast<size_t>(index)] = true;
          while (completedPrefix < windowCount && completed[static_cast<size_t>(completedPrefix)]) {
            ++completedPrefix;
          }
          prefix->advance(output, static_cast<size_t>(std::min(total, completedPrefix * step) * scale));
        }
        return fixedStage3;
      };
      if (stage == 3 && stagedDecoderStage3Parallel_ && windowCount > 1) {
        std::array<int, 2> fixedCounts{};
        std::array<std::string, 2> errors{};
        auto worker = [&](size_t lane) {
          @autoreleasepool {
            try {
              MLModel *model = lane == 0 ? stagedDecoderModels_[2] :
                stagedDecoderStage3Parallel_;
              for (int64_t index = static_cast<int64_t>(lane);
                   index < windowCount; index += 2) {
                if (processWindow(index, model)) ++fixedCounts[lane];
              }
            } catch (const std::exception &e) {
              errors[lane] = e.what();
            }
          }
        };
        dispatch_apply(2, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
          ^(size_t lane) { worker(lane); });
        if (!errors[0].empty() || !errors[1].empty()) {
          // Never replay or recompute a possibly different backend after PCM
          // has been sent to the output. The caller cancels this utterance.
          if (prefix) throw std::runtime_error("Incremental decoder failed: " + errors[0] + errors[1]);
          NSLog(@"Irodori parallel decoder stage %d failed, retrying serially: %s / %s",
                stage, errors[0].c_str(), errors[1].c_str());
          stagedDecoderStage3Parallel_ = nil;
          for (int64_t index = 0; index < windowCount; ++index) {
            if (processWindow(index, nil)) ++fixedWindows;
          }
          metrics[[NSString stringWithFormat:@"decoderStage%dParallelFallback", stage]] = @1;
        } else {
          fixedWindows = fixedCounts[0] + fixedCounts[1];
          metrics[[NSString stringWithFormat:@"decoderStage%dParallelUsed", stage]] = @1;
        }
      } else {
        for (int64_t index = 0; index < windowCount; ++index) {
          // An explicit model disables runStagedCoreML's backend fallback.
          MLModel *model = stage == 3 && prefix ? stagedDecoderModels_[2] : nil;
          if (processWindow(index, model)) ++fixedWindows;
        }
      }
      windows = static_cast<int>(windowCount);
      metrics[[NSString stringWithFormat:@"decoderStage%dWindows", stage]] = @(windows);
      if (fixedStage3All || fixedStage3First) {
        metrics[@"decoderStage3FixedWindows"] = @(fixedWindows);
      }
      return Tensor::f({1, channels, total * scale}, std::move(output));
    };
    started = Clock::now();
    current = tiled(current, 2, stagedDecoderWidths_[1], 5, 10, 384);
    metrics[@"decoderStage2Ms"] = @(elapsedMs(started));
    recordStats(current, 2);
    started = Clock::now();
    // On macOS the GPU path at width 256 produced a large numerical error;
    // width 255 remained close to the ONNX decoder in the same comparison.
    current = tiled(current, 3, stagedDecoderWidths_[2], 10, 16, 1);
    metrics[@"decoderStage3Ms"] = @(elapsedMs(started));
    recordStats(current, 3);
    for (int stage = 1; stage <= 3; ++stage) {
      metrics[[NSString stringWithFormat:@"decoderStage%dComputeMode", stage]] =
        @(stage == 1 ? stage1Mode : stagedDecoderModes_[stage - 1]);
      if (profileInference_) {
        const std::array<NSString *, 3> names = {@"InputSetup", @"Prediction", @"OutputCopy"};
        for (int phase = 0; phase < 3; ++phase) {
          metrics[[NSString stringWithFormat:@"decoderStage%d%@WorkMs", stage, names[phase]]] =
            @(decoderPhaseNanos_[(stage - 1) * 3 + phase].load(std::memory_order_relaxed) / 1e6);
        }
      }
    }
    return std::move(current.floats);
  }

  std::vector<float> decodeSplit(Tensor latent, NSMutableDictionary *metrics) {
    const char *inputs[] = {"latent", "/decoder/model.0/Conv_output_0",
                            "/decoder/model.1/block.8/Add_output_0"};
    const char *outputs[] = {"/decoder/model.0/Conv_output_0",
                             "/decoder/model.1/block.8/Add_output_0",
                             "/decoder/model.2/block.8/Add_output_0"};
    for (int stage = 0; stage < 3; ++stage) {
      auto started = Clock::now();
      Tensors stageInput;
      stageInput.emplace(inputs[stage], std::move(latent));
      Tensors stageOutput = run("decoder_stage_" + std::to_string(stage), stageInput);
      latent = std::move(stageOutput.at(outputs[stage]));
      metrics[[NSString stringWithFormat:@"decoderStage%dMs", stage]] = @(elapsedMs(started));
    }
    if (latent.shape.size() != 3 || latent.shape[0] != 1 || latent.shape[1] != 384) {
      throw std::runtime_error("Unexpected decoder stage 2 shape");
    }
    const int64_t total = latent.shape[2];
    std::vector<float> audio(total * 16);
    auto started = Clock::now();
    int windows = 0;
    int fixedWindows = 0;
    for (int64_t start = 0; start < total; start += 236) {
      const int64_t left = std::max<int64_t>(0, start - 10);
      const int64_t right = std::min<int64_t>(total, start + 246);
      const int64_t width = right - left;
      std::vector<float> window(384 * width);
      for (int64_t channel = 0; channel < 384; ++channel) {
        const float *source = latent.floats.data() + channel * total + left;
        std::copy(source, source + width, window.data() + channel * width);
      }
      Tensors stageInput;
      stageInput.emplace("/decoder/model.2/block.8/Add_output_0",
                         Tensor::f({1, 384, width}, std::move(window)));
      const bool useFixed = width == 256 && hasFixedStage3_;
      Tensors stageOutput = run(useFixed ? "decoder_stage_3_256" : "decoder_stage_3", stageInput);
      const auto &decoded = stageOutput.at("waveform").floats;
      const int64_t count = std::min<int64_t>(236, total - start) * 16;
      const int64_t crop = (start - left) * 16;
      if (static_cast<int64_t>(decoded.size()) < crop + count) {
        throw std::runtime_error("Decoder stage 3 returned too few samples");
      }
      std::copy(decoded.data() + crop, decoded.data() + crop + count,
                audio.data() + start * 16);
      ++windows;
      if (useFixed) ++fixedWindows;
    }
    metrics[@"decoderStage3Ms"] = @(elapsedMs(started));
    metrics[@"decoderStage3Windows"] = @(windows);
    metrics[@"decoderStage3FixedWindows"] = @(fixedWindows);
    return audio;
  }

  Tensors run(const std::string &name, const Tensors &inputs) {
#if defined(IRODORI_COREML_ONLY)
    return sessions_.at(name)->run(inputs);
#else
    Ort::Session &session = *sessions_.at(name);
    Ort::AllocatorWithDefaultOptions allocator;
    Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::vector<std::string> inputNames, outputNames;
    std::vector<const char *> inputPointers, outputPointers;
    std::vector<Ort::Value> values;
    inputNames.reserve(session.GetInputCount());
    inputPointers.reserve(session.GetInputCount());
    values.reserve(session.GetInputCount());
    for (size_t i = 0; i < session.GetInputCount(); ++i) {
      auto allocated = session.GetInputNameAllocated(i, allocator);
      inputNames.emplace_back(allocated.get());
      const Tensor &t = inputs.at(inputNames.back());
      inputPointers.push_back(inputNames.back().c_str());
      if (t.integers.empty()) {
        values.emplace_back(Ort::Value::CreateTensor<float>(memory,
          const_cast<float *>(t.floats.data()), t.floats.size(), t.shape.data(), t.shape.size()));
      } else {
        values.emplace_back(Ort::Value::CreateTensor<int64_t>(memory,
          const_cast<int64_t *>(t.integers.data()), t.integers.size(), t.shape.data(), t.shape.size()));
      }
    }
    for (size_t i = 0; i < session.GetOutputCount(); ++i) {
      auto allocated = session.GetOutputNameAllocated(i, allocator);
      outputNames.emplace_back(allocated.get());
    }
    for (const auto &output : outputNames) outputPointers.push_back(output.c_str());
    auto outputs = session.Run(Ort::RunOptions{nullptr}, inputPointers.data(), values.data(),
                               values.size(), outputPointers.data(), outputPointers.size());
    Tensors result;
    for (size_t i = 0; i < outputs.size(); ++i) {
      auto info = outputs[i].GetTensorTypeAndShapeInfo();
      auto shape = info.GetShape();
      size_t count = info.GetElementCount();
      if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        throw std::runtime_error("Unexpected non-FP32 output: " + outputNames[i]);
      }
      const float *ptr = outputs[i].GetTensorData<float>();
      result.emplace(outputNames[i], Tensor::f(std::move(shape), std::vector<float>(ptr, ptr + count)));
    }
    return result;
#endif
  }

#if defined(IRODORI_COREML_ONLY)
  std::unordered_map<std::string, std::unique_ptr<IrodoriCoreMLSession>> sessions_;
#else
  Ort::Env env_;
  std::unordered_map<std::string, std::unique_ptr<Ort::Session>> sessions_;
#endif
  std::unordered_map<std::string, size_t> sessionLoadCounts_;
  std::unordered_map<std::string, std::pair<int64_t, float>> vocab_;
  Tensors referenceSpeaker_;
  Tensors noRefSpeaker_;
  std::string cachedCaptionText_;
  Tensor cachedCaption_;
  bool splitContext_ = false;
  Tensors cachedSpeakerContext_;
  size_t cachedSpeakerContextBytes_ = 0;
  MLModel *nativeDit_ = nil;
  bool nativeDitNeAllowed_ = false;
  MLMultiArrayDataType nativeDitDataType_ = MLMultiArrayDataTypeFloat32;
  bool nativeDitCached_ = false;
  int64_t maxLatentFrames_ = 64;
  size_t maxTextTokens_ = 64;
  NSString *nativeDitPrecision_ = @"none";
  MLModel *nativeDecoder_ = nil;
  std::array<MLModel *, 3> stagedDecoderModels_{};
  MLModel *stagedDecoderStage3Parallel_ = nil;
  MLModel *stagedDecoderStage1Flexible_ = nil;
  MLModel *stagedDecoderStage1Fixed57_ = nil;
  MLModel *stagedDecoderStage1Enumerated_ = nil;
  std::set<int64_t> stagedDecoderStage1EnumeratedWidths_;
  std::array<NSURL *, 3> stagedDecoderCompiledUrls_{};
  std::array<int, 3> stagedDecoderModes_{}; // 0=all, 1=CPU/GPU, 2=CPU.
  std::array<int, 3> stagedDecoderWidths_{64, 128, 255};
  int onnxThreads_ = 2;
  bool onnxAllowSpinning_ = true;
  bool quantizedTextEncoder_ = false;
  bool innerPools_ = false;
  bool profileInference_ = false;
  bool fixedSeed_ = false;
  bool compactWeights_ = false;
  bool stopIdleSpin_ = false;
  bool transientReference_ = false;
  bool trimAuxiliarySessions_ = true;
  bool stage1OnnxFallbackAvailable_ = false;
  size_t auxiliaryHeapReleasedBytes_ = 0;
  double auxiliaryHeapReliefMs_ = 0;
  bool recomputeReference_ = false;
  bool referenceCacheHit_ = false;
  std::array<std::atomic<int64_t>, 9> decoderPhaseNanos_{};
  std::array<bool, 3> stagedDecoderFixed_{};
  std::vector<float> debugDitStep0_;
  bool stagedDecoder_ = false;
  bool splitDecoder_ = false;
  bool hasFixedStage3_ = false;
  bool useCoreML_ = false;
  bool fastDiT_ = false;
  std::string root_;
  size_t maxPieceBytes_ = 0;
};
} // namespace

@implementation IrodoriLocalBridge {
  std::unique_ptr<Engine> _engine;
}

- (BOOL)loadModelAtPath:(NSString *)path useCoreML:(BOOL)useCoreML
                  fastDiT:(BOOL)fastDiT error:(NSError **)error {
  try {
    // Release the old DiT, decoder and ONNX sessions before constructing the
    // replacement. Assignment constructs the new engine first and can double
    // peak memory when switching between standard and fast DiT.
    _engine.reset();
    _engine = std::make_unique<Engine>(path.fileSystemRepresentation, useCoreML, fastDiT);
    return YES;
  } catch (const std::exception &e) {
    if (error) *error = [NSError errorWithDomain:@"IrodoriLocalBridge" code:1
      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()]}];
    return NO;
  }
}

- (nullable NSDictionary<NSString *, id> *)synthesizeText:(NSString *)text error:(NSError **)error {
  return [self synthesizeText:text onPcm:nil error:error];
}

- (nullable NSDictionary<NSString *, id> *)synthesizeText:(NSString *)text
                                                  onPcm:(IrodoriPcmCallback)onPcm error:(NSError **)error {
  return [self synthesizeText:text caption:@"" onPcm:onPcm error:error];
}

- (nullable NSDictionary<NSString *, id> *)synthesizeText:(NSString *)text
                                                 caption:(NSString *)caption
                                                  onPcm:(IrodoriPcmCallback)onPcm error:(NSError **)error {
  return [self synthesizeText:text caption:caption seed:nil onPcm:onPcm error:error];
}

- (nullable NSDictionary<NSString *, id> *)synthesizeText:(NSString *)text
                                                 caption:(NSString *)caption
                                                    seed:(NSNumber *)seed
                                                  onPcm:(IrodoriPcmCallback)onPcm error:(NSError **)error {
  try {
    if (!_engine) throw std::runtime_error("Irodori model is not loaded");
    return _engine->synthesize(text, caption, seed, onPcm);
  } catch (const std::exception &e) {
    if (error) *error = [NSError errorWithDomain:@"IrodoriLocalBridge" code:2
      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()]}];
    return nil;
  }
}

- (BOOL)setReferencePcmData:(NSData *)pcmData error:(NSError **)error {
  try {
    if (!_engine) throw std::runtime_error("Irodori model is not loaded");
    if (pcmData.length % sizeof(float) != 0) throw std::runtime_error("Reference PCM must be Float32");
    _engine->setReference(static_cast<const float *>(pcmData.bytes), pcmData.length / sizeof(float));
    return YES;
  } catch (const std::exception &e) {
    if (error) *error = [NSError errorWithDomain:@"IrodoriLocalBridge" code:3
      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()]}];
    return NO;
  }
}

- (void)releaseResources { _engine.reset(); }

- (BOOL)referenceCacheHit { return _engine && _engine->referenceCacheHit(); }

- (void)clearReference {
  if (_engine) _engine->setReference(nullptr, 0);
}
@end
