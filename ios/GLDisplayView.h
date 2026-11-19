#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import "../shared/protocol.h"

@interface GLDisplayView : UIView

@property (nonatomic) BOOL fillScreen;
@property (nonatomic, readonly) CGRect activeImageRectInPoints;
@property (nonatomic, readonly) uint16_t retinaWidth;
@property (nonatomic, readonly) uint16_t retinaHeight;

- (void)applyTileBatchData:(NSData *)payload flags:(uint8_t)flags tileCount:(uint16_t)tileCount;
- (void)displayH264PixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)updateCursor:(IPD2Cursor)cursor;
- (void)clearDisplay;
- (void)teardownGL;

@end
