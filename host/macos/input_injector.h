#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "../../shared/protocol.h"

@interface InputInjector : NSObject

@property (nonatomic) CGDirectDisplayID targetDisplayID;

- (void)handleInput:(const IPD2Input *)input;

@end
