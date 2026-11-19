#import <Foundation/Foundation.h>

@protocol USBMuxBridgeDelegate <NSObject>
- (void)usbMuxDidConnectSocket:(int)fd deviceID:(uint32_t)deviceID serial:(NSString *)serial;
- (void)usbMuxDeviceListChanged:(NSUInteger)usbDeviceCount;
@end

@interface USBMuxBridge : NSObject

@property (nonatomic, weak) id<USBMuxBridgeDelegate> delegate;
@property (nonatomic, readonly) NSUInteger attachedDeviceCount;

- (instancetype)initWithTargetPort:(uint16_t)port;
- (void)start;
- (void)stop;
- (void)notifySocketClosedForDeviceID:(uint32_t)deviceID;

@end
