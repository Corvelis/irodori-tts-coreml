#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^IrodoriPcmCallback)(NSData *pcm16);

@interface IrodoriLocalBridge : NSObject
- (BOOL)loadModelAtPath:(NSString *)path useCoreML:(BOOL)useCoreML
                  fastDiT:(BOOL)fastDiT error:(NSError **)error;
- (BOOL)setReferencePcmData:(NSData *)pcmData error:(NSError **)error;
@property(nonatomic, readonly) BOOL referenceCacheHit;
- (void)clearReference;
- (nullable NSDictionary<NSString *, id> *)synthesizeText:(NSString *)text
                                                   error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)synthesizeText:(NSString *)text
                                                  onPcm:(nullable IrodoriPcmCallback)onPcm
                                                  error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)synthesizeText:(NSString *)text
                                                 caption:(NSString *)caption
                                                  onPcm:(nullable IrodoriPcmCallback)onPcm
                                                  error:(NSError **)error;
- (void)releaseResources;
@end

NS_ASSUME_NONNULL_END
