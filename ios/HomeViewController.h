#import <UIKit/UIKit.h>
#import "ConnectionManager.h"

@interface HomeViewController : UIViewController <ConnectionManagerDelegate>
@property (nonatomic, strong, readonly) ConnectionManager *connection;
@end
