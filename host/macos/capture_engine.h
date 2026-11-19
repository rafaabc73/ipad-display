#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "../../shared/protocol.h"
#import "virtual_display.h"

@protocol CaptureEngineDelegate <NSObject>
- (BOOL)hasActiveClients;
- (BOOL)hasH264Clients;
- (BOOL)hasTileOnlyClients;
- (void)captureEngineDidProduceTileBatch:(NSData *)packet
                                   flags:(uint8_t)flags
                               tileCount:(uint16_t)tileCount
                              toH264Only:(BOOL)h264Only
                            toTileOnly:(BOOL)tileOnly;
- (void)captureEngineDidProduceH264Config:(NSData *)configPayload;
- (void)captureEngineDidProduceH264Frame:(NSData *)framePayload isKeyframe:(BOOL)isKey;
- (void)captureEngineDidUpdateCursor:(const IPD2Cursor *)cursor;
- (void)captureEngineDidChangeDisplayInfo:(const IPD2DisplayInfo *)info;
@end

@interface CaptureEngine : NSObject

@property (nonatomic, weak) id<CaptureEngineDelegate> delegate;
@property (nonatomic, strong, readonly) VirtualDisplayManager *virtualDisplay;
@property (nonatomic, readonly) uint8_t currentMode;
@property (nonatomic, readonly) uint8_t currentPreset;
@property (nonatomic, readonly) uint8_t currentPosition;
@property (nonatomic, readonly) CGDirectDisplayID activeDisplayID;
@property (nonatomic, readonly) uint16_t fbWidth;
@property (nonatomic, readonly) uint16_t fbHeight;
@property (nonatomic, readonly) uint16_t logicalWidth;
@property (nonatomic, readonly) uint16_t logicalHeight;
@property (nonatomic, readonly) uint16_t videoWidth;
@property (nonatomic, readonly) uint16_t videoHeight;
@property (nonatomic, readonly) uint16_t currentFPS;

- (void)setMode:(uint8_t)mode preset:(uint8_t)preset position:(uint8_t)position;
- (void)requestFullSync;
- (void)fillDisplayInfo:(IPD2DisplayInfo *)info transport:(uint8_t)transport rttTenthMs:(uint16_t)rtt;
- (void)shutdown;

@end
