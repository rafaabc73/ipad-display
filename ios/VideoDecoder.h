#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@protocol VideoDecoderDelegate <NSObject>
- (void)videoDecoderDidOutputPixelBuffer:(CVPixelBufferRef)pixelBuffer ptsUs:(uint64_t)ptsUs;
@end

@interface VideoDecoder : NSObject

@property (nonatomic, weak) id<VideoDecoderDelegate> delegate;
@property (nonatomic, readonly) uint16_t videoWidth;
@property (nonatomic, readonly) uint16_t videoHeight;
@property (nonatomic, readonly) BOOL isReady;

- (BOOL)configureWithSPS:(const uint8_t *)sps spsLen:(size_t)spsLen
                     pps:(const uint8_t *)pps ppsLen:(size_t)ppsLen
                   width:(uint16_t)width height:(uint16_t)height;
- (BOOL)decodeAVCCData:(const uint8_t *)data length:(size_t)length ptsUs:(uint64_t)ptsUs;
- (void)reset;

@end
