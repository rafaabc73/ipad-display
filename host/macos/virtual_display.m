#import "virtual_display.h"
#import "../../shared/protocol.h"
#include <stdio.h>
#include <unistd.h>

// Private CoreGraphics Virtual Display API (macOS 12–15)
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic, retain) dispatch_queue_t queue;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, retain) NSArray *modes;
@property (nonatomic) uint32_t hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

@interface VirtualDisplayManager ()
@property (nonatomic, strong) CGVirtualDisplay *virtualDisplay;
@property (nonatomic, readwrite) CGDirectDisplayID displayID;
@property (nonatomic, readwrite) BOOL isActive;
@property (nonatomic, readwrite) uint16_t logicalWidth;
@property (nonatomic, readwrite) uint16_t logicalHeight;
@property (nonatomic, readwrite) uint16_t pixelWidth;
@property (nonatomic, readwrite) uint16_t pixelHeight;
@property (nonatomic) uint8_t currentPreset;
@property (nonatomic) uint8_t currentPosition;
@end

@implementation VirtualDisplayManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _displayID = kCGNullDirectDisplay;
        _isActive = NO;
        _currentPreset = 255;
        _currentPosition = 255;
    }
    return self;
}

- (void)dealloc {
    [self destroyDisplay];
}

- (void)targetDimensionsForPreset:(uint8_t)preset
                           logW:(size_t *)outLogW
                           logH:(size_t *)outLogH
                           pixW:(size_t *)outPixW
                           pixH:(size_t *)outPixH {
    switch (preset) {
        case IPD2_PRESET_WORKSPACE:
            // 1280x960 logical @ 2x HiDPI = 2560x1920 backing (supersampled cleanly to 2048x1536)
            *outLogW = 1280; *outLogH = 960;
            *outPixW = 2560; *outPixH = 1920;
            break;
        case IPD2_PRESET_SMOOTH:
            // 1024x768 1x low-bandwidth mode
            *outLogW = 1024; *outLogH = 768;
            *outPixW = 1024; *outPixH = 768;
            break;
        case IPD2_PRESET_RETINA:
        default:
            // 1024x768 logical @ 2x HiDPI = 2048x1536 exact 1:1 iPad 4 Retina
            *outLogW = 1024; *outLogH = 768;
            *outPixW = 2048; *outPixH = 1536;
            break;
    }
}

- (BOOL)applyModeAndPosition:(uint8_t)preset position:(uint8_t)position {
    if (!self.virtualDisplay || self.displayID == kCGNullDirectDisplay) return NO;

    size_t wantLogW = 1024, wantLogH = 768, wantPixW = 2048, wantPixH = 1536;
    [self targetDimensionsForPreset:preset logW:&wantLogW logH:&wantLogH pixW:&wantPixW pixH:&wantPixH];

    // Wait up to 1.5s for WindowServer to publish modes
    CGDisplayModeRef chosenMode = NULL;
    CFArrayRef allModes = NULL;

    for (int attempt = 0; attempt < 15; attempt++) {
        if (allModes) { CFRelease(allModes); allModes = NULL; }
        NSDictionary *opts = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
        allModes = CGDisplayCopyAllDisplayModes(self.displayID, (__bridge CFDictionaryRef)opts);
        if (allModes) {
            CFIndex count = CFArrayGetCount(allModes);
            for (CFIndex i = 0; i < count; i++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
                size_t lw = CGDisplayModeGetWidth(m);
                size_t lh = CGDisplayModeGetHeight(m);
                size_t pw = CGDisplayModeGetPixelWidth(m);
                size_t ph = CGDisplayModeGetPixelHeight(m);
                if (lw == wantLogW && lh == wantLogH && pw == wantPixW && ph == wantPixH) {
                    chosenMode = m;
                    break;
                }
            }
            if (chosenMode) break;
        }
        usleep(100000); // 100ms
    }

    // Fallback: pick highest pixel-resolution matching logical size if exact HiDPI wasn't found
    if (!chosenMode && allModes) {
        CFIndex count = CFArrayGetCount(allModes);
        for (CFIndex i = 0; i < count; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
            if (CGDisplayModeGetWidth(m) == wantLogW && CGDisplayModeGetHeight(m) == wantLogH) {
                chosenMode = m;
                if (CGDisplayModeGetPixelWidth(m) >= wantPixW) break;
            }
        }
    }

    CGDisplayConfigRef cfgRef = NULL;
    if (CGBeginDisplayConfiguration(&cfgRef) == kCGErrorSuccess) {
        // Guarantee extended desktop (never mirrored)
        CGConfigureDisplayMirrorOfDisplay(cfgRef, self.displayID, kCGNullDirectDisplay);

        if (chosenMode) {
            CGConfigureDisplayWithDisplayMode(cfgRef, self.displayID, chosenMode, NULL);
        }

        // Compute origin relative to main display
        CGRect mainB = CGDisplayBounds(CGMainDisplayID());
        int32_t ox = (int32_t)(mainB.origin.x + mainB.size.width);
        int32_t oy = (int32_t)mainB.origin.y;

        switch (position) {
            case IPD2_POS_LEFT:
                ox = (int32_t)(mainB.origin.x - (CGFloat)wantLogW);
                oy = (int32_t)mainB.origin.y;
                break;
            case IPD2_POS_TOP:
                ox = (int32_t)(mainB.origin.x + (mainB.size.width - (CGFloat)wantLogW) / 2.0);
                oy = (int32_t)(mainB.origin.y - (CGFloat)wantLogH);
                break;
            case IPD2_POS_BOTTOM:
                ox = (int32_t)(mainB.origin.x + (mainB.size.width - (CGFloat)wantLogW) / 2.0);
                oy = (int32_t)(mainB.origin.y + mainB.size.height);
                break;
            case IPD2_POS_RIGHT:
            default:
                ox = (int32_t)(mainB.origin.x + mainB.size.width);
                oy = (int32_t)mainB.origin.y;
                break;
        }

        CGConfigureDisplayOrigin(cfgRef, self.displayID, ox, oy);
        CGError err = CGCompleteDisplayConfiguration(cfgRef, kCGConfigureForSession);
        if (err != kCGErrorSuccess) {
            fprintf(stderr, "[VirtualDisplay] CGCompleteDisplayConfiguration error: %d\n", (int)err);
        }
    }

    if (allModes) CFRelease(allModes);

    // Give WindowServer a moment to apply the mode
    usleep(250000);

    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(self.displayID);
    if (cur) {
        self.logicalWidth  = (uint16_t)CGDisplayModeGetWidth(cur);
        self.logicalHeight = (uint16_t)CGDisplayModeGetHeight(cur);
        self.pixelWidth    = (uint16_t)CGDisplayModeGetPixelWidth(cur);
        self.pixelHeight   = (uint16_t)CGDisplayModeGetPixelHeight(cur);
        CGDisplayModeRelease(cur);
    } else {
        self.logicalWidth  = (uint16_t)wantLogW;
        self.logicalHeight = (uint16_t)wantLogH;
        self.pixelWidth    = (uint16_t)wantPixW;
        self.pixelHeight   = (uint16_t)wantPixH;
    }

    self.currentPreset = preset;
    self.currentPosition = position;

    fprintf(stderr, "[VirtualDisplay] Ativo! ID=%u | Lógico=%ux%u | Físico=%ux%u (%.0fx Retina) | Pos=%u\n",
            self.displayID, self.logicalWidth, self.logicalHeight,
            self.pixelWidth, self.pixelHeight,
            self.logicalWidth > 0 ? (double)self.pixelWidth / self.logicalWidth : 1.0,
            position);

    return (self.logicalWidth > 1 && self.logicalHeight > 1);
}

- (BOOL)ensureDisplayWithPreset:(uint8_t)preset position:(uint8_t)position {
    if (self.virtualDisplay && self.isActive) {
        if (self.currentPreset == preset && self.currentPosition == position) {
            return YES;
        }
        return [self applyModeAndPosition:preset position:position];
    }

    fprintf(stderr, "[VirtualDisplay] Criando monitor virtual HiDPI 2x (Retina 4:3)...\n");
    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.name = @"iPad Retina Display";
    desc.maxPixelsWide = 2560;
    desc.maxPixelsHigh = 1920;
    desc.sizeInMillimeters = CGSizeMake(197, 148); // Exact 9.7" iPad 4 physical screen size
    desc.queue = dispatch_get_main_queue();
    desc.vendorID = 0x05AC;
    desc.productID = 0x12AB;
    desc.serialNum = 0x2048;

    self.virtualDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!self.virtualDisplay) {
        fprintf(stderr, "[VirtualDisplay] Falha ao alocar CGVirtualDisplay.\n");
        return NO;
    }

    CGVirtualDisplayMode *m1024 = [[CGVirtualDisplayMode alloc] initWithWidth:1024 height:768 refreshRate:60.0];
    CGVirtualDisplayMode *m1280 = [[CGVirtualDisplayMode alloc] initWithWidth:1280 height:960 refreshRate:60.0];
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = 1;
    settings.modes = @[m1024, m1280];

    if (![self.virtualDisplay applySettings:settings]) {
        fprintf(stderr, "[VirtualDisplay] Falha ao aplicar CGVirtualDisplaySettings.\n");
        self.virtualDisplay = nil;
        return NO;
    }

    self.displayID = self.virtualDisplay.displayID;
    self.isActive = YES;

    return [self applyModeAndPosition:preset position:position];
}

- (BOOL)reconfigurePreset:(uint8_t)preset position:(uint8_t)position {
    if (!self.virtualDisplay || !self.isActive) {
        return [self ensureDisplayWithPreset:preset position:position];
    }
    return [self applyModeAndPosition:preset position:position];
}

- (void)destroyDisplay {
    if (self.virtualDisplay) {
        fprintf(stderr, "[VirtualDisplay] Removendo monitor virtual (ID=%u)...\n", self.displayID);
        self.virtualDisplay = nil;
    }
    self.displayID = kCGNullDirectDisplay;
    self.isActive = NO;
    self.logicalWidth = 0;
    self.logicalHeight = 0;
    self.pixelWidth = 0;
    self.pixelHeight = 0;
    self.currentPreset = 255;
    self.currentPosition = 255;
}

@end
