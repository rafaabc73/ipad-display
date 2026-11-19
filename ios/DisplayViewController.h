#import <UIKit/UIKit.h>
#import "../shared/protocol.h"
#import "ConnectionManager.h"
#import "GLDisplayView.h"
#import "VideoDecoder.h"

@protocol DisplayViewControllerDelegate <NSObject>
- (void)displayViewControllerDidRequestBack:(UIViewController *)vc;
- (void)displayViewControllerDidSelectMode:(uint8_t)mode;
- (void)displayViewControllerDidSelectPreset:(uint8_t)preset;
@end

@interface DisplayViewController : UIViewController <VideoDecoderDelegate>

@property (nonatomic, weak) id<DisplayViewControllerDelegate> delegate;
@property (nonatomic, strong) ConnectionManager *connection;
@property (nonatomic, strong, readonly) GLDisplayView *glView;
@property (nonatomic, strong, readonly) VideoDecoder *videoDecoder;
@property (nonatomic) uint8_t activeMode;
@property (nonatomic) uint8_t activePreset;

- (void)handleTileBatch:(NSData *)payload flags:(uint8_t)flags tileCount:(uint16_t)tileCount seq:(uint32_t)seq;
- (void)handleH264Config:(NSData *)payload;
- (void)handleH264Frame:(NSData *)payload isKeyframe:(BOOL)isKey seq:(uint32_t)seq;
- (void)handleCursor:(IPD2Cursor)cursor;
- (void)handleDisplayInfo:(IPD2DisplayInfo)info;
- (void)showDisconnectedBanner;

@end
