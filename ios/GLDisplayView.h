#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import "../shared/protocol.h"

@interface GLDisplayView : UIView

@property (nonatomic) BOOL fillScreen;
@property (nonatomic, readonly) CGRect activeImageRectInPoints;
@property (nonatomic, readonly) uint16_t retinaWidth;
@property (nonatomic, readonly) uint16_t retinaHeight;
@property (nonatomic, readonly) int backingWidth;
@property (nonatomic, readonly) int backingHeight;
@property (nonatomic, copy) void (^onFramePresented)(uint32_t seq);
@property (nonatomic, copy) void (^onFirstFrameVisible)(void);

- (void)applyTileBatchData:(NSData *)payload flags:(uint8_t)flags tileCount:(uint16_t)tileCount seq:(uint32_t)seq;
- (void)displayH264PixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)updateCursor:(IPD2Cursor)cursor;
- (void)clearDisplay;
- (void)teardownGL;

@end
