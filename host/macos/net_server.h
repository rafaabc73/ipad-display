#import <Foundation/Foundation.h>
#import "../../shared/protocol.h"
#import "capture_engine.h"
#import "input_injector.h"
#import "usbmux_bridge.h"

@protocol NetServerStatusDelegate <NSObject>
- (void)netServerStatusDidChange:(NSString *)statusText clientCount:(NSUInteger)count;
@end

@interface NetServer : NSObject <CaptureEngineDelegate, USBMuxBridgeDelegate>

@property (nonatomic, weak) id<NetServerStatusDelegate> statusDelegate;
@property (nonatomic, strong, readonly) CaptureEngine *captureEngine;
@property (nonatomic, strong, readonly) InputInjector *inputInjector;
@property (nonatomic, strong, readonly) USBMuxBridge *usbMux;

- (instancetype)initWithPublicDir:(NSString *)publicDir
                         httpPort:(uint16_t)httpPort
                          tcpPort:(uint16_t)tcpPort;
- (BOOL)start;
- (void)stop;
- (void)printConnectionBanner;
- (NSArray<NSDictionary *> *)detectedAddresses;

@end
