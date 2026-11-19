#import <Foundation/Foundation.h>
#import "../shared/protocol.h"

@protocol ConnectionManagerDelegate <NSObject>
- (void)connectionDidConnectViaTransport:(uint8_t)transport peerLabel:(NSString *)label;
- (void)connectionDidDisconnect;
- (void)connectionDidReceiveDisplayInfo:(IPD2DisplayInfo)info;
- (void)connectionDidReceiveTileBatch:(NSData *)payload flags:(uint8_t)flags tileCount:(uint16_t)tileCount seq:(uint32_t)seq;
- (void)connectionDidReceiveH264Config:(NSData *)payload;
- (void)connectionDidReceiveH264Frame:(NSData *)payload isKeyframe:(BOOL)isKey seq:(uint32_t)seq;
- (void)connectionDidReceiveCursor:(IPD2Cursor)cursor;
- (void)connectionDidUpdateDiscoveredHosts:(NSArray<NSDictionary *> *)hosts;
@end

@interface ConnectionManager : NSObject

@property (nonatomic, weak) id<ConnectionManagerDelegate> delegate;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) uint8_t activeTransport;
@property (nonatomic, readonly) IPD2DisplayInfo lastDisplayInfo;

- (void)start;
- (void)stop;
- (void)connectToManualHost:(NSString *)host port:(uint16_t)port;
- (void)sendControlCmd:(uint8_t)cmd arg1:(uint8_t)arg1;
- (void)sendInput:(IPD2Input)input;
- (void)sendFrameAck:(uint32_t)seq;

@end
