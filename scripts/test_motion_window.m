#import <Cocoa/Cocoa.h>

@interface MotionTestView : NSView
@property (nonatomic) int frameIdx;
@end

@implementation MotionTestView
- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    [[NSColor colorWithRed:0.11 green:0.15 blue:0.23 alpha:1.0] setFill];
    NSRectFill(b);

    // Large high-contrast moving browser window (>50% area changes per frame)
    CGFloat w = b.size.width * 0.68;
    CGFloat h = b.size.height * 0.68;
    CGFloat phase = (CGFloat)(self.frameIdx % 40) / 40.0;
    CGFloat x = (b.size.width - w) * (0.5 + 0.48 * sin(phase * M_PI * 2.0));
    CGFloat y = (b.size.height - h) * (0.5 + 0.42 * cos(phase * M_PI * 2.0));

    [[NSColor colorWithRed:0.97 green:0.98 blue:1.0 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(x, y, w, h));

    [[NSColor colorWithRed:0.0 green:0.46 blue:0.92 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(x, y + h - 48, w, 48));

    [[NSColor colorWithRed:0.16 green:0.18 blue:0.22 alpha:1.0] setFill];
    for (int i = 0; i < 12; i++) {
        NSRectFill(NSMakeRect(x + 24, y + 28 + i * 32, w * (0.35 + ((i * 19) % 55) / 100.0), 12));
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSScreen *target = nil;
        CGDirectDisplayID mainID = CGMainDisplayID();
        for (NSScreen *scr in [NSScreen screens]) {
            NSNumber *num = scr.deviceDescription[@"NSScreenNumber"];
            if (num && (CGDirectDisplayID)num.unsignedIntValue != mainID) {
                target = scr;
                break;
            }
        }
        if (!target) {
            fprintf(stderr, "NO_SECONDARY_SCREEN\n");
            return 1;
        }

        NSWindow *win = [[NSWindow alloc] initWithContentRect:target.frame
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        [win setFrame:target.frame display:YES];
        [win setLevel:NSFloatingWindowLevel];
        [win setOpaque:YES];
        [win setIgnoresMouseEvents:YES];

        MotionTestView *view = [[MotionTestView alloc] initWithFrame:NSMakeRect(0, 0, target.frame.size.width, target.frame.size.height)];
        [win setContentView:view];
        [win orderFrontRegardless];

        fprintf(stdout, "MOTION_START\n");
        fflush(stdout);

        __block int frames = 0;
        __block BOOL stoppedPrinted = NO;
        [NSTimer scheduledTimerWithTimeInterval:(1.0 / 60.0) repeats:YES block:^(NSTimer *timer) {
            frames++;
            if (frames <= 72) { // 1.2s of continuous 60 FPS motion
                view.frameIdx = frames;
                [view setNeedsDisplay:YES];
            } else if (!stoppedPrinted) {
                stoppedPrinted = YES;
                fprintf(stdout, "MOTION_STOP\n");
                fflush(stdout);
            } else if (frames >= 115) { // +0.7s static settle for Retina sharpen recovery
                [timer invalidate];
                [win orderOut:nil];
                [NSApp stop:nil];
                // Post dummy event so [NSApp run] exits immediately
                NSEvent *ev = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                 location:NSZeroPoint modifierFlags:0 timestamp:0
                                             windowNumber:0 context:nil subtype:0 data1:0 data2:0];
                [NSApp postEvent:ev atStart:YES];
            }
        }];

        [NSApp run];
    }
    return 0;
}
