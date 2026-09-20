#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface LGTensorBuffer : NSObject
- (instancetype)initWithPointer:(void *)pointer count:(NSUInteger)count;
@property(nonatomic, readonly) void *pointer;
@property(nonatomic, readonly) NSUInteger count;
@end

/// Buffers are borrowed for one synchronous prediction. They must not escape it.
@protocol LGModelProvider <NSObject>
- (BOOL)predictModel:(NSString *)name
              inputs:(NSDictionary<NSString *, LGTensorBuffer *> *)inputs
             outputs:(NSDictionary<NSString *, LGTensorBuffer *> *)outputs
               error:(NSError * _Nullable * _Nullable)error;
@end

/// Confined to a single serial processing queue. No camera or network access.
@interface LGFramePipeline : NSObject
- (instancetype)initWithModels:(id<LGModelProvider>)models;
- (void)reset;
- (BOOL)processPixelBuffer:(CVPixelBufferRef)input
                     into:(CVPixelBufferRef)output
                    error:(NSError * _Nullable * _Nullable)error;
@property(nonatomic, readonly) NSString *lastStatus;
@property(nonatomic, readonly) NSString *lastReason;
@property(nonatomic) BOOL profilingEnabled;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *lastStageTimings;
@end

NS_ASSUME_NONNULL_END
