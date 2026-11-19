#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface VirtualDisplayManager : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) BOOL isActive;
@property (nonatomic, readonly) uint16_t logicalWidth;
@property (nonatomic, readonly) uint16_t logicalHeight;
@property (nonatomic, readonly) uint16_t pixelWidth;
@property (nonatomic, readonly) uint16_t pixelHeight;

- (BOOL)ensureDisplayWithPreset:(uint8_t)preset position:(uint8_t)position;
- (BOOL)reconfigurePreset:(uint8_t)preset position:(uint8_t)position;
- (void)destroyDisplay;

@end
