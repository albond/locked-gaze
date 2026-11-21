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
/// How far the gaze is moved toward the camera: 1 (default) aims fully at the lens;
/// lower values leave that share of the observed eye movement. Clamped to 0...1.
@property(nonatomic) double correctionStrength;
/// Adds brief glances a few degrees off the lens at random intervals. Off by default.
@property(nonatomic) BOOL naturalLookAways;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *lastStageTimings;
@end

NS_ASSUME_NONNULL_END
