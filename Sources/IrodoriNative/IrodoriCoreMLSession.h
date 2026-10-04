// FP32 auxiliary backend for the app and standalone Core ML builds.
// Included inside the engine namespace when IRODORI_COREML_ONLY is defined.
// Tensor, Tensors and compiledCoreMLModel are supplied by the host engine.
#pragma once

class IrodoriCoreMLSession {
 public:
  IrodoriCoreMLSession(NSString *root, const std::string &name)
      : referenceEncoder_(name == "dacvae_encode") {
    NSString *component = referenceEncoder_ ? @"dacvae_encode_stats" :
      [NSString stringWithUTF8String:name.c_str()];
    NSString *base = [root stringByAppendingPathComponent:component];
    NSData *data = [NSData dataWithContentsOfFile:[base stringByAppendingPathExtension:@"json"]];
    NSDictionary *metadata = data ? [NSJSONSerialization JSONObjectWithData:data
      options:0 error:nil] : nil;
    if (![metadata isKindOfClass:NSDictionary.class])
      throw std::runtime_error("Missing or invalid Core ML component metadata: " + name);
    inputs_ = metadata[@"inputs"];
    outputs_ = metadata[@"outputs"];
    if (![inputs_ isKindOfClass:NSArray.class] || !inputs_.count ||
        ![outputs_ isKindOfClass:NSDictionary.class] || !outputs_.count ||
        ![metadata[@"compute_precision"] isEqual:@"float32"]) {
      throw std::runtime_error("Invalid Core ML component metadata: " + name);
    }
    NSError *error = nil;
    NSURL *compiled = compiledCoreMLModel([base stringByAppendingPathExtension:@"mlpackage"], &error);
    MLModelConfiguration *config = [MLModelConfiguration new];
    config.computeUnits = MLComputeUnitsCPUOnly;
    model_ = compiled ? [MLModel modelWithContentsOfURL:compiled configuration:config error:&error] : nil;
    if (!model_) throw std::runtime_error("Core ML load failed: " + name + ": " +
      (error ? error.localizedDescription.UTF8String : "unknown error"));
    for (NSString *input in inputs_) {
      if (!model_.modelDescription.inputDescriptionsByName[input]) {
        throw std::runtime_error("Missing Core ML input: " + std::string(input.UTF8String));
      }
    }
  }

  Tensors run(const Tensors &inputs) {
    @autoreleasepool {
      NSMutableDictionary *features = [NSMutableDictionary dictionary];
      for (NSString *name in inputs_) {
        const Tensor &t = inputs.at(name.UTF8String);
        NSMutableArray *shape = [NSMutableArray array];
        size_t count = 1;
        for (int64_t dim : t.shape) {
          if (dim <= 0 || count > SIZE_MAX / static_cast<size_t>(dim))
            throw std::runtime_error("Invalid auxiliary tensor shape");
          count *= dim; [shape addObject:@(dim)];
        }
        const bool integer = !t.integers.empty();
        if (t.shape.empty() || count != (integer ? t.integers.size() : t.floats.size()))
          throw std::runtime_error("Invalid auxiliary tensor size");
        NSError *error = nil;
        MLMultiArray *array = [[MLMultiArray alloc] initWithShape:shape
          dataType:integer ? MLMultiArrayDataTypeInt32 : MLMultiArrayDataTypeFloat32 error:&error];
        if (!array) throw std::runtime_error("Auxiliary tensor allocation failed");
        const Layout layout(array);
        if (!integer && layout.contiguous) {
          std::memcpy(array.dataPointer, t.floats.data(), count * sizeof(float));
        } else for (size_t flat = 0; flat < count; ++flat) {
          size_t offset = layout.offsetFor(flat);
          if (integer) {
            int64_t value = t.integers[flat];
            if (value < INT32_MIN || value > INT32_MAX)
              throw std::runtime_error("Auxiliary integer input overflow");
            static_cast<int32_t *>(array.dataPointer)[offset] = static_cast<int32_t>(value);
          } else static_cast<float *>(array.dataPointer)[offset] = t.floats[flat];
        }
        features[name] = [MLFeatureValue featureValueWithMultiArray:array];
      }
      NSError *error = nil;
      MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc]
        initWithDictionary:features error:&error];
      id<MLFeatureProvider> prediction = provider ? [model_ predictionFromFeatures:provider error:&error] : nil;
      if (!prediction) throw std::runtime_error(error ? error.localizedDescription.UTF8String :
        "Auxiliary Core ML prediction failed");
      Tensors result;
      for (NSString *name in outputs_) {
        MLMultiArray *array = [prediction featureValueForName:outputs_[name]].multiArrayValue;
        if (!array || array.dataType != MLMultiArrayDataTypeFloat32)
          throw std::runtime_error("Auxiliary output must be Float32");
        std::vector<int64_t> shape;
        for (NSNumber *dim in array.shape) shape.push_back(dim.longLongValue);
        std::vector<float> values(array.count);
        const float *source = static_cast<const float *>(array.dataPointer);
        const Layout layout(array);
        if (layout.contiguous) std::memcpy(values.data(), source, values.size() * sizeof(float));
        else for (size_t flat = 0; flat < values.size(); ++flat)
          values[flat] = source[layout.offsetFor(flat)];
        result.emplace(name.UTF8String, Tensor::f(std::move(shape), std::move(values)));
      }
      if (referenceEncoder_) return sampleReference(std::move(result));
      return result;
    }
  }

 private:
  struct Layout {
    std::vector<size_t> shape, strides;
    bool contiguous = true;
    explicit Layout(MLMultiArray *array) {
      for (NSNumber *value in array.shape) shape.push_back(value.unsignedLongLongValue);
      for (NSNumber *value in array.strides) strides.push_back(value.unsignedLongLongValue);
      size_t expected = 1;
      for (size_t i = shape.size(); i-- > 0;) {
        contiguous &= strides[i] == expected;
        expected *= shape[i];
      }
    }
    size_t offsetFor(size_t flat) const {
      if (contiguous) return flat;
      size_t offset = 0;
      for (size_t i = shape.size(); i-- > 0;) {
        offset += (flat % shape[i]) * strides[i]; flat /= shape[i];
      }
      return offset;
    }
  };

  Tensors sampleReference(Tensors stats) {
    // Match the deployed ONNX seed=0 sampler, including its channel-major
    // draw order. Verified against ORT 1.17.3 on Apple libc++ (3,808 values).
    // Separate multiplication/addition retain the original ONNX operations.
#pragma clang fp contract(off)
    const Tensor &mean = stats.at("/Slice_output_0");
    const Tensor &scale = stats.at("/Add_1_output_0");
    if (mean.shape.size() != 3 || mean.shape[0] != 1 || mean.shape[1] != 32 ||
        mean.shape != scale.shape) throw std::runtime_error("Invalid reference statistics");
    const size_t frames = mean.shape[2];
    std::normal_distribution<float> normal(0.f, 1.f);
    std::vector<float> latent(mean.floats.size());
    for (size_t channel = 0; channel < 32; ++channel) {
      for (size_t frame = 0; frame < frames; ++frame) {
        const size_t index = channel * frames + frame;
        const float delta = scale.floats[index] * normal(random_);
        latent[frame * 32 + channel] = mean.floats[index] + delta;
      }
    }
    return {{"latent", Tensor::f({1, static_cast<int64_t>(frames), 32}, std::move(latent))}};
  }

  MLModel *model_ = nil;
  NSArray<NSString *> *inputs_;
  NSDictionary<NSString *, NSString *> *outputs_;
  bool referenceEncoder_;
  std::default_random_engine random_{0};
};
