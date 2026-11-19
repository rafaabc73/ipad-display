#import "input_injector.h"
#include <unistd.h>

@implementation InputInjector

- (instancetype)init {
    self = [super init];
    if (self) {
        _targetDisplayID = CGMainDisplayID();
    }
    return self;
}

- (CGPoint)pointFromNormalizedX:(float)nx y:(float)ny {
    if (nx < 0.0f) nx = 0.0f;
    if (nx > 1.0f) nx = 1.0f;
    if (ny < 0.0f) ny = 0.0f;
    if (ny > 1.0f) ny = 1.0f;

    CGDirectDisplayID dID = self.targetDisplayID;
    if (dID == kCGNullDirectDisplay) dID = CGMainDisplayID();
    CGRect bounds = CGDisplayBounds(dID);
    if (bounds.size.width <= 1.0 || bounds.size.height <= 1.0) {
        bounds = CGDisplayBounds(CGMainDisplayID());
    }

    return CGPointMake(bounds.origin.x + nx * bounds.size.width,
                       bounds.origin.y + ny * bounds.size.height);
}

- (CGEventFlags)cgFlagsFromModifiers:(uint8_t)mods {
    CGEventFlags f = 0;
    if (mods & 0x01) f |= kCGEventFlagMaskShift;
    if (mods & 0x02) f |= kCGEventFlagMaskControl;
    if (mods & 0x04) f |= kCGEventFlagMaskAlternate;
    if (mods & 0x08) f |= kCGEventFlagMaskCommand;
    return f;
}

- (void)postMouseEvent:(CGEventType)type point:(CGPoint)pt button:(CGMouseButton)btn clickCount:(int64_t)clicks {
    CGEventRef ev = CGEventCreateMouseEvent(NULL, type, pt, btn);
    if (!ev) return;
    if (clicks > 0) {
        CGEventSetIntegerValueField(ev, kCGMouseEventClickState, clicks);
    }
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
}

- (void)handleInput:(const IPD2Input *)input {
    if (!input) return;

    switch (input->eventType) {
        case IPD2_INPUT_MOVE: {
            CGPoint pt = [self pointFromNormalizedX:input->x y:input->y];
            [self postMouseEvent:kCGEventMouseMoved point:pt button:kCGMouseButtonLeft clickCount:0];
            break;
        }
        case IPD2_INPUT_LEFT_DOWN: {
            CGPoint pt = [self pointFromNormalizedX:input->x y:input->y];
            int64_t clicks = input->clickCount > 0 ? input->clickCount : 1;
            [self postMouseEvent:kCGEventMouseMoved point:pt button:kCGMouseButtonLeft clickCount:0];
            [self postMouseEvent:kCGEventLeftMouseDown point:pt button:kCGMouseButtonLeft clickCount:clicks];
            break;
        }
        case IPD2_INPUT_LEFT_DRAG: {
            CGPoint pt = [self pointFromNormalizedX:input->x y:input->y];
            [self postMouseEvent:kCGEventLeftMouseDragged point:pt button:kCGMouseButtonLeft clickCount:1];
            break;
        }
        case IPD2_INPUT_LEFT_UP: {
            CGPoint pt = [self pointFromNormalizedX:input->x y:input->y];
            int64_t clicks = input->clickCount > 0 ? input->clickCount : 1;
            [self postMouseEvent:kCGEventLeftMouseUp point:pt button:kCGMouseButtonLeft clickCount:clicks];
            break;
        }
        case IPD2_INPUT_DOUBLE_CLICK: {
            CGPoint pt = [self pointFromNormalizedX:input->x y:input->y];
            [self postMouseEvent:kCGEventMouseMoved point:pt button:kCGMouseButtonLeft clickCount:0];
            [self postMouseEvent:kCGEventLeftMouseDown point:pt button:kCGMouseButtonLeft clickCount:1];
            [self postMouseEvent:kCGEventLeftMouseUp point:pt button:kCGMouseButtonLeft clickCount:1];
            usleep(12000);
            [self postMouseEvent:kCGEventLeftMouseDown point:pt button:kCGMouseButtonLeft clickCount:2];
            [self postMouseEvent:kCGEventLeftMouseUp point:pt button:kCGMouseButtonLeft clickCount:2];
            break;
        }
        case IPD2_INPUT_RIGHT_DOWN: {
            CGPoint pt = [self pointFromNormalizedX:input->x y:input->y];
            [self postMouseEvent:kCGEventMouseMoved point:pt button:kCGMouseButtonRight clickCount:0];
            [self postMouseEvent:kCGEventRightMouseDown point:pt button:kCGMouseButtonRight clickCount:1];
            break;
        }
        case IPD2_INPUT_RIGHT_UP: {
            CGPoint pt = [self pointFromNormalizedX:input->x y:input->y];
            [self postMouseEvent:kCGEventRightMouseUp point:pt button:kCGMouseButtonRight clickCount:1];
            break;
        }
        case IPD2_INPUT_SCROLL: {
            // Ensure cursor is inside target display before scrolling
            CGDirectDisplayID dID = self.targetDisplayID ? self.targetDisplayID : CGMainDisplayID();
            CGRect bounds = CGDisplayBounds(dID);
            CGEventRef curEv = CGEventCreate(NULL);
            if (curEv) {
                CGPoint curPt = CGEventGetLocation(curEv);
                CFRelease(curEv);
                if (!CGRectContainsPoint(bounds, curPt)) {
                    CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
                    [self postMouseEvent:kCGEventMouseMoved point:center button:kCGMouseButtonLeft clickCount:0];
                }
            }
            int32_t dy = (int32_t)input->y;
            int32_t dx = (int32_t)input->x;
            CGEventRef scrollEv = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, dy, dx);
            if (scrollEv) {
                CGEventPost(kCGHIDEventTap, scrollEv);
                CFRelease(scrollEv);
            }
            break;
        }
        case IPD2_INPUT_KEY_CHAR: {
            uint32_t ch = input->keyData;
            if (ch == 0 || ch > 0xFFFF) break;
            UniChar u = (UniChar)ch;
            CGEventFlags flags = [self cgFlagsFromModifiers:input->modifiers];
            CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
            CGEventRef up   = CGEventCreateKeyboardEvent(NULL, 0, false);
            if (down && up) {
                CGEventKeyboardSetUnicodeString(down, 1, &u);
                CGEventKeyboardSetUnicodeString(up, 1, &u);
                if (flags) {
                    CGEventSetFlags(down, flags);
                    CGEventSetFlags(up, flags);
                }
                CGEventPost(kCGHIDEventTap, down);
                CGEventPost(kCGHIDEventTap, up);
            }
            if (down) CFRelease(down);
            if (up) CFRelease(up);
            break;
        }
        case IPD2_INPUT_KEY_SPECIAL: {
            CGKeyCode code = 0xFFFF;
            switch (input->keyData) {
                case 1: code = 0x24; break; // Return
                case 2: code = 0x33; break; // Delete / Backspace
                case 3: code = 0x30; break; // Tab
                case 4: code = 0x35; break; // Escape
                case 5: code = 0x7B; break; // Left Arrow
                case 6: code = 0x7C; break; // Right Arrow
                case 7: code = 0x7E; break; // Up Arrow
                case 8: code = 0x7D; break; // Down Arrow
                default: break;
            }
            if (code == 0xFFFF) break;
            CGEventFlags flags = [self cgFlagsFromModifiers:input->modifiers];
            CGEventRef down = CGEventCreateKeyboardEvent(NULL, code, true);
            CGEventRef up   = CGEventCreateKeyboardEvent(NULL, code, false);
            if (down && up) {
                if (flags) {
                    CGEventSetFlags(down, flags);
                    CGEventSetFlags(up, flags);
                }
                CGEventPost(kCGHIDEventTap, down);
                CGEventPost(kCGHIDEventTap, up);
            }
            if (down) CFRelease(down);
            if (up) CFRelease(up);
            break;
        }
        default:
            break;
    }
}

@end
