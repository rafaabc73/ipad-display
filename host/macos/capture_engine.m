#import "capture_engine.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import "../../shared/lz4/lz4.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#define TILE_SIZE 128

static uint64_t now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
}

@interface CaptureEngine () <SCStreamOutput> {
    uint8_t *_prevFrame;
    size_t   _prevFrameSize;
    uint8_t *_tileScratch;
    size_t   _tileScratchSize;
    uint8_t *_lz4Scratch;
    size_t   _lz4ScratchSize;
    uint16_t *_rgb565Scratch;
    size_t   _rgb565ScratchSize;

    CVPixelBufferRef _latestPB;
    VTCompressionSessionRef _vtSession;
    VTPixelTransferSessionRef _vtTransfer;
    CVPixelBufferPoolRef _videoPBPool;

    NSData *_cachedH264Config;
    BOOL _sentH264ConfigToCurrent;
    BOOL _forceH264Keyframe;
    BOOL _inMotionBurst;
    BOOL _needsSharpen;
    BOOL _forceFullSync;

    float _lastCursorX;
    float _lastCursorY;
    uint8_t _lastCursorVisible;
    uint64_t _lastMotionUs;

    uint32_t _fpsFrames;
    double _fpsLastTime;
}

@property (nonatomic, strong, readwrite) VirtualDisplayManager *virtualDisplay;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) dispatch_queue_t engineQueue;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) dispatch_source_t cursorTimer;
@property (nonatomic, strong) dispatch_source_t sharpenTimer;

@property (nonatomic, readwrite) uint8_t currentMode;
@property (nonatomic, readwrite) uint8_t currentPreset;
@property (nonatomic, readwrite) uint8_t currentPosition;
@property (nonatomic, readwrite) CGDirectDisplayID activeDisplayID;
@property (nonatomic, readwrite) uint16_t fbWidth;
@property (nonatomic, readwrite) uint16_t fbHeight;
@property (nonatomic, readwrite) uint16_t logicalWidth;
@property (nonatomic, readwrite) uint16_t logicalHeight;
@property (nonatomic, readwrite) uint16_t videoWidth;
@property (nonatomic, readwrite) uint16_t videoHeight;
@property (nonatomic, readwrite) uint16_t currentFPS;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, copy) NSString *hostName;

- (void)handleEncodedH264SampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

static void vtOutputCallback(void *outputCallbackRefCon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTEncodeInfoFlags infoFlags,
                             CMSampleBufferRef sampleBuffer) {
    if (status != noErr || !sampleBuffer) return;
    CaptureEngine *engine = (__bridge CaptureEngine *)outputCallbackRefCon;
    [engine handleEncodedH264SampleBuffer:sampleBuffer];
}

@implementation CaptureEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        _virtualDisplay = [[VirtualDisplayManager alloc] init];
        _engineQueue  = dispatch_queue_create("ipd2.engine.queue", DISPATCH_QUEUE_SERIAL);
        _captureQueue = dispatch_queue_create("ipd2.capture.queue", DISPATCH_QUEUE_SERIAL);
        _currentMode = IPD2_MODE_IDLE;
        _currentPreset = IPD2_PRESET_RETINA;
        _currentPosition = IPD2_POS_RIGHT;
        _activeDisplayID = CGMainDisplayID();
        _hostName = [[NSHost currentHost] localizedName] ?: @"Mac";
        _lastCursorX = -1.0f;
        _lastCursorY = -1.0f;
        _lastCursorVisible = 2;
        _fpsLastTime = CACurrentMediaTime();

        _tileScratchSize = TILE_SIZE * TILE_SIZE * 4;
        _tileScratch = (uint8_t *)malloc(_tileScratchSize);
        _lz4ScratchSize = (size_t)LZ4_compressBound(2048 * 1536 * 2);
        _lz4Scratch = (uint8_t *)malloc(_lz4ScratchSize);

        [self startCursorAndSharpenTimers];
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
    if (_prevFrame) free(_prevFrame);
    if (_tileScratch) free(_tileScratch);
    if (_lz4Scratch) free(_lz4Scratch);
    if (_rgb565Scratch) free(_rgb565Scratch);
}

- (void)startCursorAndSharpenTimers {
    __weak typeof(self) weakSelf = self;

    // 60 Hz independent cursor tracker
    self.cursorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.captureQueue);
    dispatch_source_set_timer(self.cursorTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 16 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.cursorTimer, ^{
        CaptureEngine *s = weakSelf;
        if (!s || s.currentMode == IPD2_MODE_IDLE) return;
        id<CaptureEngineDelegate> del = s.delegate;
        if (!del || ![del hasActiveClients]) return;

        CGDirectDisplayID dID = s.activeDisplayID;
        if (dID == kCGNullDirectDisplay) return;
        CGRect bounds = CGDisplayBounds(dID);
        if (bounds.size.width <= 1.0 || bounds.size.height <= 1.0) return;

        CGEventRef ev = CGEventCreate(NULL);
        if (!ev) return;
        CGPoint pt = CGEventGetLocation(ev);
        CFRelease(ev);

        uint8_t vis = CGRectContainsPoint(bounds, pt) ? 1 : 0;
        float nx = vis ? (float)((pt.x - bounds.origin.x) / bounds.size.width) : s->_lastCursorX;
        float ny = vis ? (float)((pt.y - bounds.origin.y) / bounds.size.height) : s->_lastCursorY;
        if (nx < 0.0f) nx = 0.0f;
        if (nx > 1.0f) nx = 1.0f;
        if (ny < 0.0f) ny = 0.0f;
        if (ny > 1.0f) ny = 1.0f;

        if (vis != s->_lastCursorVisible ||
            (vis && (fabsf(nx - s->_lastCursorX) > 0.0002f || fabsf(ny - s->_lastCursorY) > 0.0002f))) {
            s->_lastCursorX = nx;
            s->_lastCursorY = ny;
            s->_lastCursorVisible = vis;

            IPD2Cursor cur;
            memset(&cur, 0, sizeof(cur));
            cur.normX = nx;
            cur.normY = ny;
            cur.visible = vis;
            cur.cursorType = 0;
            [del captureEngineDidUpdateCursor:&cur];
        }
    });
    dispatch_resume(self.cursorTimer);

    // 40 ms check timer for post-motion Retina sharpen pass & full sync
    self.sharpenTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.captureQueue);
    dispatch_source_set_timer(self.sharpenTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 40 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.sharpenTimer, ^{
        CaptureEngine *s = weakSelf;
        if (!s || s.currentMode == IPD2_MODE_IDLE) return;
        id<CaptureEngineDelegate> del = s.delegate;
        if (!del || ![del hasActiveClients]) return;

        if (s->_forceFullSync && s->_latestPB) {
            s->_forceFullSync = NO;
            s->_needsSharpen = NO;
            s->_inMotionBurst = NO;
            [s emitRetinaTilesFromPixelBuffer:s->_latestPB fullSync:YES];
            return;
        }

        if (s->_needsSharpen && s->_latestPB) {
            uint64_t elapsed = now_us() - s->_lastMotionUs;
            if (elapsed >= 110000ULL) { // 110ms after fast motion settles
                s->_needsSharpen = NO;
                s->_inMotionBurst = NO;
                [s emitRetinaTilesFromPixelBuffer:s->_latestPB fullSync:YES];
            }
        }
    });
    dispatch_resume(self.sharpenTimer);
}

- (void)teardownH264Encoder {
    if (_vtSession) {
        VTCompressionSessionInvalidate(_vtSession);
        CFRelease(_vtSession);
        _vtSession = NULL;
    }
    if (_vtTransfer) {
        VTPixelTransferSessionInvalidate(_vtTransfer);
        CFRelease(_vtTransfer);
        _vtTransfer = NULL;
    }
    if (_videoPBPool) {
        CVPixelBufferPoolRelease(_videoPBPool);
        _videoPBPool = NULL;
    }
    _cachedH264Config = nil;
    _sentH264ConfigToCurrent = NO;
}

- (BOOL)setupH264EncoderWidth:(uint16_t)w height:(uint16_t)h {
    [self teardownH264Encoder];
    if (w < 64 || h < 64) return NO;

    NSDictionary *encoderSpec = @{
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES
    };
    NSDictionary *srcAttrs = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferWidthKey: @(w),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(h),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    OSStatus st = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        w, h,
        kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)encoderSpec,
        (__bridge CFDictionaryRef)srcAttrs,
        NULL,
        vtOutputCallback,
        (__bridge void *)self,
        &_vtSession
    );

    if (st != noErr || !_vtSession) {
        fprintf(stderr, "[CaptureEngine] VTCompressionSessionCreate falhou: %d\n", (int)st);
        return NO;
    }

    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_4_1);
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(120));
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(60));
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(16000000)); // 16 Mbps crisp USB H.264
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(_vtSession, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    VTCompressionSessionPrepareToEncodeFrames(_vtSession);

    VTPixelTransferSessionCreate(kCFAllocatorDefault, &_vtTransfer);
    if (_vtTransfer) {
        VTSessionSetProperty(_vtTransfer, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Letterbox);
    }

    CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)srcAttrs, &_videoPBPool);
    _forceH264Keyframe = YES;

    fprintf(stderr, "[CaptureEngine] Hardware H.264 VideoToolbox pronto (%ux%u @ 60fps High 4.1 16Mbps)\n", w, h);
    return YES;
}

- (void)computeDimensionsForDisplay:(CGDirectDisplayID)dID mode:(uint8_t)mode preset:(uint8_t)preset {
    CGDisplayModeRef dm = CGDisplayCopyDisplayMode(dID);
    size_t logW = dm ? CGDisplayModeGetWidth(dm) : 1440;
    size_t logH = dm ? CGDisplayModeGetHeight(dm) : 900;
    size_t pixW = dm ? CGDisplayModeGetPixelWidth(dm) : logW;
    size_t pixH = dm ? CGDisplayModeGetPixelHeight(dm) : logH;
    if (dm) CGDisplayModeRelease(dm);

    self.logicalWidth = (uint16_t)logW;
    self.logicalHeight = (uint16_t)logH;

    uint16_t capW = 2048, capH = 1536;
    if (mode == IPD2_MODE_SECOND) {
        if (preset == IPD2_PRESET_SMOOTH) {
            capW = 1024; capH = 768;
        } else {
            // Exact 1:1 physical Retina resolution of iPad 4 (2048x1536)
            capW = 2048; capH = 1536;
        }
    } else {
        // Mirror mode: preserve exact aspect ratio of main display (e.g., 16:10 -> 2048x1280)
        double aspect = (pixH > 0) ? ((double)pixW / (double)pixH) : (16.0 / 10.0);
        uint16_t maxW = (preset == IPD2_PRESET_SMOOTH) ? 1280 : 2048;
        uint16_t maxH = (preset == IPD2_PRESET_SMOOTH) ? 960 : 1536;

        if ((double)maxW / (double)maxH > aspect) {
            capH = maxH;
            capW = (uint16_t)((double)capH * aspect);
        } else {
            capW = maxW;
            capH = (uint16_t)((double)capW / aspect);
        }
        // Align to 16 pixels for clean tile + H.264 encoding
        capW = (uint16_t)((capW + 8) & ~15);
        capH = (uint16_t)((capH + 8) & ~15);
        if (capW > 2048) capW = 2048;
        if (capH > 1536) capH = 1536;
        if (capW < 320) capW = 320;
        if (capH < 240) capH = 240;
    }

    self.fbWidth = capW;
    self.fbHeight = capH;

    // Hardware H.264 stream dimensions strictly <= 1920x1080 for Apple A6X VXD392 compatibility!
    double fbAspect = (double)capW / (double)capH;
    uint16_t vidW, vidH;
    if (1920.0 / 1080.0 > fbAspect) {
        vidH = 1080;
        vidW = (uint16_t)((double)vidH * fbAspect);
    } else {
        vidW = 1920;
        vidH = (uint16_t)((double)vidW / fbAspect);
    }
    vidW = (uint16_t)((vidW + 8) & ~15);
    vidH = (uint16_t)((vidH + 4) & ~7); // 1080 is divisible by 8 (1080 = 135*8)
    if (vidW > 1920) vidW = 1920;
    if (vidH > 1080) vidH = 1080;
    self.videoWidth = vidW;
    self.videoHeight = vidH;
}

- (void)resetFrameBuffers {
    size_t needed = (size_t)self.fbWidth * (size_t)self.fbHeight * 4;
    if (needed > _prevFrameSize || !_prevFrame) {
        if (_prevFrame) free(_prevFrame);
        _prevFrame = (uint8_t *)calloc(1, needed);
        _prevFrameSize = needed;
    } else {
        memset(_prevFrame, 0, needed);
    }

    size_t halfPixels = (size_t)((self.fbWidth / 2) + 1) * (size_t)((self.fbHeight / 2) + 1);
    if (halfPixels * sizeof(uint16_t) > _rgb565ScratchSize || !_rgb565Scratch) {
        if (_rgb565Scratch) free(_rgb565Scratch);
        _rgb565ScratchSize = halfPixels * sizeof(uint16_t);
        _rgb565Scratch = (uint16_t *)malloc(_rgb565ScratchSize);
    }

    if (_latestPB) {
        CVPixelBufferRelease(_latestPB);
        _latestPB = NULL;
    }
    _forceFullSync = YES;
    _inMotionBurst = NO;
    _needsSharpen = NO;
    _forceH264Keyframe = YES;
    _sentH264ConfigToCurrent = NO;
}

- (void)fillDisplayInfo:(IPD2DisplayInfo *)info transport:(uint8_t)transport rttTenthMs:(uint16_t)rtt {
    memset(info, 0, sizeof(IPD2DisplayInfo));
    info->mode = self.currentMode;
    info->preset = self.currentPreset;
    info->transport = transport;
    info->osKind = IPD2_OS_MACOS;
    info->fbWidth = self.fbWidth;
    info->fbHeight = self.fbHeight;
    info->logicalWidth = self.logicalWidth;
    info->logicalHeight = self.logicalHeight;
    info->videoWidth = self.videoWidth;
    info->videoHeight = self.videoHeight;
    info->fps = self.currentFPS;
    info->rttTenthMs = rtt;
    info->position = self.currentPosition;
    info->hasVirtualDisplay = 1;
    strncpy(info->hostName, [self.hostName UTF8String] ?: "Mac", sizeof(info->hostName) - 1);
}

- (void)notifyDisplayInfo {
    id<CaptureEngineDelegate> del = self.delegate;
    if (!del) return;
    IPD2DisplayInfo info;
    [self fillDisplayInfo:&info transport:IPD2_TRANSPORT_USB rttTenthMs:0];
    [del captureEngineDidChangeDisplayInfo:&info];
}

- (void)findSCDisplay:(CGDirectDisplayID)targetID
           generation:(NSUInteger)gen
              attempt:(int)attempt
           completion:(void (^)(SCDisplay *disp))completion {
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *sc, NSError *err) {
        if (gen != self.generation) return;
        if (err || !sc || sc.displays.count == 0) {
            fprintf(stderr, "[CaptureEngine] SCShareableContent erro: %s\n",
                    err ? [[err localizedDescription] UTF8String] : "sem displays");
            if (completion) completion(nil);
            return;
        }
        for (SCDisplay *d in sc.displays) {
            if (d.displayID == targetID && d.width > 1 && d.height > 1) {
                if (completion) completion(d);
                return;
            }
        }
        if (attempt < 15) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), self.engineQueue, ^{
                if (gen == self.generation) {
                    [self findSCDisplay:targetID generation:gen attempt:attempt + 1 completion:completion];
                }
            });
        } else {
            // Fallback to display ID match even if width reported differently
            for (SCDisplay *d in sc.displays) {
                if (d.displayID == targetID) {
                    if (completion) completion(d);
                    return;
                }
            }
            if (completion) completion(sc.displays.firstObject);
        }
    }];
}

- (void)setMode:(uint8_t)mode preset:(uint8_t)preset position:(uint8_t)position {
    dispatch_async(self.engineQueue, ^{
        BOOL sameMode = (mode == self.currentMode);
        BOOL samePreset = (preset == self.currentPreset);
        BOOL samePos = (position == self.currentPosition);

        if (sameMode && samePreset && samePos && (mode == IPD2_MODE_IDLE || self.stream != nil)) {
            [self requestFullSync];
            [self notifyDisplayInfo];
            return;
        }

        NSUInteger gen = ++self.generation;
        fprintf(stderr, "[CaptureEngine] Alterando modo=%u preset=%u pos=%u\n", mode, preset, position);

        // Stop previous SCStream cleanly
        if (self.stream) {
            SCStream *old = self.stream;
            self.stream = nil;
            [old stopCaptureWithCompletionHandler:nil];
        }

        self.currentMode = mode;
        self.currentPreset = preset;
        self.currentPosition = position;

        // Destroy virtual display if not in SECOND mode! (Fixes ghost display bug!)
        if (mode != IPD2_MODE_SECOND) {
            [self.virtualDisplay destroyDisplay];
        }

        if (mode == IPD2_MODE_IDLE) {
            dispatch_sync(self.captureQueue, ^{
                [self teardownH264Encoder];
                if (self->_latestPB) {
                    CVPixelBufferRelease(self->_latestPB);
                    self->_latestPB = NULL;
                }
            });
            self.activeDisplayID = CGMainDisplayID();
            self.fbWidth = 0;
            self.fbHeight = 0;
            self.currentFPS = 0;
            [self notifyDisplayInfo];
            return;
        }

        CGDirectDisplayID targetID = CGMainDisplayID();
        if (mode == IPD2_MODE_SECOND) {
            if (![self.virtualDisplay ensureDisplayWithPreset:preset position:position]) {
                fprintf(stderr, "[CaptureEngine] Falha ao criar monitor virtual; usando principal.\n");
            } else {
                targetID = self.virtualDisplay.displayID;
            }
        }

        self.activeDisplayID = targetID;
        [self computeDimensionsForDisplay:targetID mode:mode preset:preset];

        dispatch_sync(self.captureQueue, ^{
            [self resetFrameBuffers];
            [self setupH264EncoderWidth:self.videoWidth height:self.videoHeight];
        });

        [self notifyDisplayInfo];

        [self findSCDisplay:targetID generation:gen attempt:0 completion:^(SCDisplay *targetDisplay) {
            dispatch_async(self.engineQueue, ^{
                if (gen != self.generation || !targetDisplay) return;

                SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];
                SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
                cfg.width = self.fbWidth;
                cfg.height = self.fbHeight;
                cfg.pixelFormat = kCVPixelFormatType_32BGRA;
                cfg.minimumFrameInterval = CMTimeMake(1, 60);
                cfg.queueDepth = 3;
                cfg.showsCursor = NO; // Cursor sent independently at 60Hz!

                SCStream *newStream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:nil];
                NSError *addErr = nil;
                [newStream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.captureQueue error:&addErr];
                if (addErr) {
                    fprintf(stderr, "[CaptureEngine] addStreamOutput erro: %s\n", [[addErr localizedDescription] UTF8String]);
                    return;
                }

                self.stream = newStream;
                [newStream startCaptureWithCompletionHandler:^(NSError *startErr) {
                    if (startErr) {
                        fprintf(stderr, "[CaptureEngine] startCapture erro: %s\n", [[startErr localizedDescription] UTF8String]);
                    } else {
                        fprintf(stderr, "[CaptureEngine] Captura 60 FPS ativa! Display=%u | Retina=%ux%u | H264=%ux%u\n",
                                targetID, self.fbWidth, self.fbHeight, self.videoWidth, self.videoHeight);
                    }
                }];
            });
        }];
    });
}

- (void)requestFullSync {
    dispatch_async(self.captureQueue, ^{
        self->_forceFullSync = YES;
        self->_forceH264Keyframe = YES;
        self->_sentH264ConfigToCurrent = NO;
        self->_lastCursorVisible = 2; // Force cursor resend
    });
}

- (void)shutdown {
    dispatch_sync(self.engineQueue, ^{
        self.generation++;
        if (self.stream) {
            [self.stream stopCaptureWithCompletionHandler:nil];
            self.stream = nil;
        }
        [self.virtualDisplay destroyDisplay];
        self.currentMode = IPD2_MODE_IDLE;
    });
    if (self.cursorTimer) { dispatch_source_cancel(self.cursorTimer); self.cursorTimer = nil; }
    if (self.sharpenTimer) { dispatch_source_cancel(self.sharpenTimer); self.sharpenTimer = nil; }
    dispatch_sync(self.captureQueue, ^{
        [self teardownH264Encoder];
        if (self->_latestPB) {
            CVPixelBufferRelease(self->_latestPB);
            self->_latestPB = NULL;
        }
    });
}

#pragma mark - SCStreamOutput (Capture Queue)

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || self.currentMode == IPD2_MODE_IDLE) return;

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;

    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    if (w != self.fbWidth || h != self.fbHeight) return;

    // Keep latest pixel buffer for instant client sync & post-motion Retina sharpen
    if (_latestPB) CVPixelBufferRelease(_latestPB);
    _latestPB = CVPixelBufferRetain(pb);

    id<CaptureEngineDelegate> del = self.delegate;
    if (!del || ![del hasActiveClients]) return;

    // Update FPS counter
    _fpsFrames++;
    double nowT = CACurrentMediaTime();
    if (nowT - _fpsLastTime >= 1.0) {
        self.currentFPS = (uint16_t)((double)_fpsFrames / (nowT - _fpsLastTime) + 0.5);
        _fpsFrames = 0;
        _fpsLastTime = nowT;
    }

    if (_forceFullSync) {
        _forceFullSync = NO;
        _needsSharpen = NO;
        _inMotionBurst = NO;
        [self emitRetinaTilesFromPixelBuffer:pb fullSync:YES];
        return;
    }

    // Fast tile diffing (128x128 tiles)
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *srcBase = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t srcStride = CVPixelBufferGetBytesPerRow(pb);

    int cols = ((int)w + TILE_SIZE - 1) / TILE_SIZE;
    int rows = ((int)h + TILE_SIZE - 1) / TILE_SIZE;
    int totalTiles = cols * rows;
    uint8_t dirty[512]; // Supports up to 4096x2048
    memset(dirty, 0, sizeof(dirty));
    int changedCount = 0;

    for (int ty = 0; ty < rows; ty++) {
        int py = ty * TILE_SIZE;
        int th = ((int)h - py < TILE_SIZE) ? ((int)h - py) : TILE_SIZE;
        for (int tx = 0; tx < cols; tx++) {
            int px = tx * TILE_SIZE;
            int tw = ((int)w - px < TILE_SIZE) ? ((int)w - px) : TILE_SIZE;
            size_t rowBytes = (size_t)tw * 4;
            BOOL isDiff = NO;
            for (int row = 0; row < th; row++) {
                const uint8_t *sRow = srcBase + (size_t)(py + row) * srcStride + (size_t)px * 4;
                const uint8_t *pRow = _prevFrame + ((size_t)(py + row) * w + (size_t)px) * 4;
                if (memcmp(sRow, pRow, rowBytes) != 0) {
                    isDiff = YES;
                    break;
                }
            }
            if (isDiff) {
                dirty[ty * cols + tx] = 1;
                changedCount++;
            }
        }
    }

    if (changedCount == 0) {
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        return;
    }

    BOOL heavyMotion = (changedCount > (totalTiles * 35) / 100);
    BOOL hasH264 = [del hasH264Clients];
    BOOL hasTileOnly = [del hasTileOnlyClients];

    if (heavyMotion) {
        _inMotionBurst = YES;
        _needsSharpen = YES;
        _lastMotionUs = now_us();

        // 1. Native iOS clients: Hardware VideoToolbox H.264 @ 60 FPS!
        if (hasH264 && _vtSession && _vtTransfer && _videoPBPool) {
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            [self encodeH264FrameFromPixelBuffer:pb];
            // If PWA clients are also connected, re-lock for fast half-res RGB565 motion
            if (hasTileOnly) {
                CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                [self emitFastMotionRGB565FromBase:(const uint8_t *)CVPixelBufferGetBaseAddress(pb)
                                            stride:CVPixelBufferGetBytesPerRow(pb)
                                             width:(int)w height:(int)h
                                        toTileOnly:YES];
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            }
            return;
        }

        // 2. PWA-only heavy motion: Half-res 16-bit RGB565 + LZ4 (ultra-fast 30-60 FPS!)
        if (hasTileOnly) {
            [self emitFastMotionRGB565FromBase:srcBase stride:srcStride width:(int)w height:(int)h toTileOnly:NO];
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            return;
        }
    }

    // Normal desktop / UI / typing / coding: 100% LOSSLESS 2048x1536 RETINA LZ4 BGRA TILES!
    [self emitDirtyRetinaTilesFromBase:srcBase
                                stride:srcStride
                                 width:(int)w
                                height:(int)h
                                 dirty:dirty
                                  cols:cols
                                  rows:rows
                              fullSync:_inMotionBurst];
    _inMotionBurst = NO;
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

#pragma mark - Lossless Retina Tile Encoder

- (void)emitRetinaTilesFromPixelBuffer:(CVPixelBufferRef)pb fullSync:(BOOL)fullSync {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *srcBase = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t srcStride = CVPixelBufferGetBytesPerRow(pb);
    int w = (int)CVPixelBufferGetWidth(pb);
    int h = (int)CVPixelBufferGetHeight(pb);
    int cols = (w + TILE_SIZE - 1) / TILE_SIZE;
    int rows = (h + TILE_SIZE - 1) / TILE_SIZE;
    uint8_t dirty[512];
    memset(dirty, 1, (size_t)(cols * rows));

    [self emitDirtyRetinaTilesFromBase:srcBase stride:srcStride width:w height:h
                                 dirty:dirty cols:cols rows:rows fullSync:fullSync];
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

- (void)emitDirtyRetinaTilesFromBase:(const uint8_t *)srcBase
                              stride:(size_t)srcStride
                               width:(int)w
                              height:(int)h
                               dirty:(const uint8_t *)dirty
                                cols:(int)cols
                                rows:(int)rows
                            fullSync:(BOOL)fullSync {
    id<CaptureEngineDelegate> del = self.delegate;
    if (!del) return;

    // Emit in bounded batches (<= 32 tiles per packet) so GPU uploads stay super snappy
    NSMutableData *batch = [NSMutableData dataWithCapacity:256 * 1024];
    IPD2TileBatchHeader bh = { (uint16_t)w, (uint16_t)h };
    [batch appendBytes:&bh length:sizeof(bh)];
    uint16_t countInBatch = 0;
    BOOL sentAny = NO;

    for (int ty = 0; ty < rows; ty++) {
        int py = ty * TILE_SIZE;
        int th = (h - py < TILE_SIZE) ? (h - py) : TILE_SIZE;
        for (int tx = 0; tx < cols; tx++) {
            if (!dirty[ty * cols + tx]) continue;
            int px = tx * TILE_SIZE;
            int tw = (w - px < TILE_SIZE) ? (w - px) : TILE_SIZE;
            size_t rowBytes = (size_t)tw * 4;
            int rawBytes = tw * th * 4;

            // Copy into contiguous scratch & update _prevFrame simultaneously
            for (int row = 0; row < th; row++) {
                const uint8_t *sRow = srcBase + (size_t)(py + row) * srcStride + (size_t)px * 4;
                uint8_t *pRow = _prevFrame + ((size_t)(py + row) * (size_t)w + (size_t)px) * 4;
                uint8_t *tRow = _tileScratch + (size_t)row * rowBytes;
                memcpy(pRow, sRow, rowBytes);
                memcpy(tRow, sRow, rowBytes);
            }

            int compSize = LZ4_compress_fast((const char *)_tileScratch,
                                             (char *)_lz4Scratch,
                                             rawBytes,
                                             (int)_lz4ScratchSize,
                                             2);

            IPD2TileHeader thdr;
            thdr.x = (uint16_t)px;
            thdr.y = (uint16_t)py;
            thdr.w = (uint16_t)tw;
            thdr.h = (uint16_t)th;
            thdr.pad = 0;

            if (compSize > 0 && compSize < rawBytes) {
                thdr.encoding = IPD2_ENC_LZ4_BGRA;
                thdr.dataLen = (uint32_t)compSize;
                [batch appendBytes:&thdr length:sizeof(thdr)];
                [batch appendBytes:_lz4Scratch length:(NSUInteger)compSize];
            } else {
                thdr.encoding = IPD2_ENC_RAW_BGRA;
                thdr.dataLen = (uint32_t)rawBytes;
                [batch appendBytes:&thdr length:sizeof(thdr)];
                [batch appendBytes:_tileScratch length:(NSUInteger)rawBytes];
            }
            countInBatch++;

            if (countInBatch >= 32) {
                uint8_t flags = fullSync ? IPD2_TILE_FLAG_FULL_SYNC : 0;
                [del captureEngineDidProduceTileBatch:[batch copy]
                                                flags:flags
                                            tileCount:countInBatch
                                           toH264Only:NO
                                           toTileOnly:NO];
                sentAny = YES;
                [batch setLength:sizeof(bh)];
                countInBatch = 0;
            }
        }
    }

    if (countInBatch > 0) {
        uint8_t flags = fullSync ? IPD2_TILE_FLAG_FULL_SYNC : 0;
        [del captureEngineDidProduceTileBatch:batch
                                        flags:flags
                                    tileCount:countInBatch
                                   toH264Only:NO
                                   toTileOnly:NO];
        sentAny = YES;
    } else if (fullSync && !sentAny) {
        // Send 0-tile FULL_SYNC signal so Native App switches back to Retina texture cleanly
        [del captureEngineDidProduceTileBatch:batch
                                        flags:IPD2_TILE_FLAG_FULL_SYNC
                                    tileCount:0
                                   toH264Only:NO
                                   toTileOnly:NO];
    }
}

#pragma mark - Fast Half-Res RGB565 Motion Encoder (PWA 30-60 FPS Motion)

- (void)emitFastMotionRGB565FromBase:(const uint8_t *)srcBase
                              stride:(size_t)srcStride
                               width:(int)w
                              height:(int)h
                          toTileOnly:(BOOL)tileOnly {
    id<CaptureEngineDelegate> del = self.delegate;
    if (!del || !_rgb565Scratch) return;

    int hw = w / 2;
    int hh = h / 2;
    if (hw < 64 || hh < 64) return;

    // 2x fast downsample BGRA -> RGB565 (2 bytes/px)
    for (int y = 0; y < hh; y++) {
        const uint8_t *sRow = srcBase + (size_t)(y * 2) * srcStride;
        uint16_t *dRow = _rgb565Scratch + (size_t)y * (size_t)hw;
        for (int x = 0; x < hw; x++) {
            const uint8_t *p = sRow + (size_t)(x * 2) * 4;
            uint16_t b = p[0] >> 3;
            uint16_t g = p[1] >> 2;
            uint16_t r = p[2] >> 3;
            dRow[x] = (uint16_t)((r << 11) | (g << 5) | b);
        }
    }

    int rawBytes = hw * hh * 2;
    int compSize = LZ4_compress_fast((const char *)_rgb565Scratch,
                                     (char *)_lz4Scratch,
                                     rawBytes,
                                     (int)_lz4ScratchSize,
                                     4);

    NSMutableData *batch = [NSMutableData dataWithCapacity:(NSUInteger)(compSize > 0 ? compSize + 64 : rawBytes + 64)];
    IPD2TileBatchHeader bh = { (uint16_t)hw, (uint16_t)hh };
    [batch appendBytes:&bh length:sizeof(bh)];

    IPD2TileHeader thdr;
    thdr.x = 0;
    thdr.y = 0;
    thdr.w = (uint16_t)hw;
    thdr.h = (uint16_t)hh;
    thdr.pad = 0;

    if (compSize > 0 && compSize < rawBytes) {
        thdr.encoding = IPD2_ENC_LZ4_RGB565;
        thdr.dataLen = (uint32_t)compSize;
        [batch appendBytes:&thdr length:sizeof(thdr)];
        [batch appendBytes:_lz4Scratch length:(NSUInteger)compSize];
    } else {
        thdr.encoding = IPD2_ENC_RAW_RGB565;
        thdr.dataLen = (uint32_t)rawBytes;
        [batch appendBytes:&thdr length:sizeof(thdr)];
        [batch appendBytes:_rgb565Scratch length:(NSUInteger)rawBytes];
    }

    [del captureEngineDidProduceTileBatch:batch
                                    flags:IPD2_TILE_FLAG_HALF_RES
                                tileCount:1
                               toH264Only:NO
                               toTileOnly:tileOnly];
}

#pragma mark - Hardware VideoToolbox H.264 Encoder (Native iOS 60 FPS Motion)

- (void)encodeH264FrameFromPixelBuffer:(CVPixelBufferRef)srcPB {
    CVPixelBufferRef scaledPB = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _videoPBPool, &scaledPB) != kCVReturnSuccess || !scaledPB) {
        return;
    }

    OSStatus xferSt = VTPixelTransferSessionTransferImage(_vtTransfer, srcPB, scaledPB);
    if (xferSt != noErr) {
        CVPixelBufferRelease(scaledPB);
        return;
    }

    NSDictionary *frameProps = nil;
    if (_forceH264Keyframe) {
        frameProps = @{ (__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES };
        _forceH264Keyframe = NO;
    }

    CMTime pts = CMTimeMake((int64_t)now_us(), 1000000);
    CMTime dur = CMTimeMake(1, 60);
    VTCompressionSessionEncodeFrame(_vtSession, scaledPB, pts, dur, (__bridge CFDictionaryRef)frameProps, NULL, NULL);
    CVPixelBufferRelease(scaledPB);
}

- (void)handleEncodedH264SampleBuffer:(CMSampleBufferRef)sampleBuffer {
    id<CaptureEngineDelegate> del = self.delegate;
    if (!del || ![del hasH264Clients]) return;

    BOOL isKey = YES;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef att = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = (CFBooleanRef)CFDictionaryGetValue(att, kCMSampleAttachmentKey_NotSync);
        if (notSync && CFBooleanGetValue(notSync)) {
            isKey = NO;
        }
    }

    if (isKey) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (fmt) {
            const uint8_t *sps = NULL, *pps = NULL;
            size_t spsLen = 0, ppsLen = 0;
            size_t paramCount = 0;
            int nalLenSize = 4;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &spsLen, &paramCount, &nalLenSize) == noErr &&
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &ppsLen, NULL, NULL) == noErr) {
                NSMutableData *cfgData = [NSMutableData dataWithCapacity:sizeof(IPD2H264ConfigHeader) + spsLen + ppsLen];
                IPD2H264ConfigHeader ch;
                ch.videoW = self.videoWidth;
                ch.videoH = self.videoHeight;
                ch.spsLen = (uint16_t)spsLen;
                ch.ppsLen = (uint16_t)ppsLen;
                [cfgData appendBytes:&ch length:sizeof(ch)];
                [cfgData appendBytes:sps length:spsLen];
                [cfgData appendBytes:pps length:ppsLen];
                _cachedH264Config = cfgData;
                _sentH264ConfigToCurrent = YES;
                [del captureEngineDidProduceH264Config:cfgData];
            }
        }
    } else if (!_sentH264ConfigToCurrent && _cachedH264Config) {
        // Wait for keyframe if config hasn't been sent yet
        _forceH264Keyframe = YES;
        return;
    }

    CMBlockBufferRef blockBuf = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuf) return;

    size_t totalLen = 0;
    char *dataPtr = NULL;
    if (CMBlockBufferGetDataPointer(blockBuf, 0, NULL, &totalLen, &dataPtr) != kCMBlockBufferNoErr || !dataPtr || totalLen == 0) {
        // Non-contiguous block buffer fallback
        totalLen = CMBlockBufferGetDataLength(blockBuf);
        if (totalLen == 0) return;
        NSMutableData *payload = [NSMutableData dataWithLength:sizeof(IPD2H264FrameHeader) + totalLen];
        IPD2H264FrameHeader *fh = (IPD2H264FrameHeader *)payload.mutableBytes;
        fh->ptsUs = now_us();
        CMBlockBufferCopyDataBytes(blockBuf, 0, totalLen, (uint8_t *)payload.mutableBytes + sizeof(IPD2H264FrameHeader));
        [del captureEngineDidProduceH264Frame:payload isKeyframe:isKey];
        return;
    }

    NSMutableData *payload = [NSMutableData dataWithCapacity:sizeof(IPD2H264FrameHeader) + totalLen];
    IPD2H264FrameHeader fh;
    fh.ptsUs = now_us();
    [payload appendBytes:&fh length:sizeof(fh)];
    [payload appendBytes:dataPtr length:totalLen];
    [del captureEngineDidProduceH264Frame:payload isKeyframe:isKey];
}

@end
