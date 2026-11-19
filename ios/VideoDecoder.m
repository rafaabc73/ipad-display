#import "VideoDecoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#include <string.h>

@interface VideoDecoder () {
    VTDecompressionSessionRef _session;
    CMVideoFormatDescriptionRef _formatDesc;
    NSLock *_lock;
}
@property (nonatomic, readwrite) uint16_t videoWidth;
@property (nonatomic, readwrite) uint16_t videoHeight;
@property (nonatomic, readwrite) BOOL isReady;
@property (nonatomic, strong) NSData *lastSPS;
@property (nonatomic, strong) NSData *lastPPS;
@end

static void vtDecodeCallback(void *decompressionOutputRefCon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVImageBufferRef imageBuffer,
                             CMTime presentationTimeStamp,
                             CMTime presentationDuration) {
    if (status != noErr || !imageBuffer) return;
    VideoDecoder *dec = (__bridge VideoDecoder *)decompressionOutputRefCon;
    id<VideoDecoderDelegate> del = dec.delegate;
    if (del) {
        uint64_t pts = (uint64_t)(CMTimeGetSeconds(presentationTimeStamp) * 1000000.0);
        [del videoDecoderDidOutputPixelBuffer:imageBuffer ptsUs:pts];
    }
}

@implementation VideoDecoder

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self reset];
}

- (void)resetLocked {
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDesc) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
    self.isReady = NO;
    self.videoWidth = 0;
    self.videoHeight = 0;
    self.lastSPS = nil;
    self.lastPPS = nil;
}

- (void)reset {
    [_lock lock];
    [self resetLocked];
    [_lock unlock];
}

- (BOOL)configureWithSPS:(const uint8_t *)sps spsLen:(size_t)spsLen
                     pps:(const uint8_t *)pps ppsLen:(size_t)ppsLen
                   width:(uint16_t)width height:(uint16_t)height {
    [_lock lock];
    if (!sps || spsLen == 0 || !pps || ppsLen == 0) {
        [_lock unlock];
        return NO;
    }

    NSData *newSPS = [NSData dataWithBytes:sps length:spsLen];
    NSData *newPPS = [NSData dataWithBytes:pps length:ppsLen];
    if (_session && self.isReady &&
        [self.lastSPS isEqualToData:newSPS] &&
        [self.lastPPS isEqualToData:newPPS]) {
        [_lock unlock];
        return YES;
    }

    [self resetLocked];

    const uint8_t *paramSets[2] = { sps, pps };
    const size_t paramSizes[2] = { spsLen, ppsLen };

    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        2,
        paramSets,
        paramSizes,
        4, // AVCC 4-byte length prefix
        &_formatDesc
    );
    if (st != noErr || !_formatDesc) {
        [_lock unlock];
        return NO;
    }

    // Apple A6X hardware decoder outputs NV12 video-range directly into OpenGL ES compatible IOSurface!
    NSDictionary *destAttrs = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    VTDecompressionOutputCallbackRecord cb;
    cb.decompressionOutputCallback = vtDecodeCallback;
    cb.decompressionOutputRefCon = (__bridge void *)self;

    st = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _formatDesc,
        NULL,
        (__bridge CFDictionaryRef)destAttrs,
        &cb,
        &_session
    );

    if (st != noErr || !_session) {
        NSLog(@"[VideoDecoder] VTDecompressionSessionCreate FAILED: %d (%ux%u)", (int)st, width, height);
        [self resetLocked];
        [_lock unlock];
        return NO;
    }

    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    NSLog(@"[VideoDecoder] Hardware H.264 ready (%ux%u)", width, height);

    self.lastSPS = newSPS;
    self.lastPPS = newPPS;
    self.videoWidth = width;
    self.videoHeight = height;
    self.isReady = YES;
    [_lock unlock];
    return YES;
}

- (BOOL)decodeAVCCData:(const uint8_t *)data length:(size_t)length ptsUs:(uint64_t)ptsUs {
    [_lock lock];
    if (!_session || !_formatDesc || !data || length == 0) {
        [_lock unlock];
        return NO;
    }

    // Copy into CMBlockBuffer owned memory so decode is 100% memory-safe
    CMBlockBufferRef blockBuf = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        NULL,
        length,
        kCFAllocatorDefault,
        NULL,
        0,
        length,
        0,
        &blockBuf
    );
    if (st != noErr || !blockBuf) {
        [_lock unlock];
        return NO;
    }

    st = CMBlockBufferReplaceDataBytes(data, blockBuf, 0, length);
    if (st != noErr) {
        CFRelease(blockBuf);
        [_lock unlock];
        return NO;
    }

    CMSampleBufferRef sampleBuf = NULL;
    const size_t sampleSizeArray[1] = { length };
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, 60);
    timing.presentationTimeStamp = CMTimeMake((int64_t)ptsUs, 1000000);
    timing.decodeTimeStamp = kCMTimeInvalid;

    st = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        blockBuf,
        _formatDesc,
        1,
        1,
        &timing,
        1,
        sampleSizeArray,
        &sampleBuf
    );
    CFRelease(blockBuf);

    if (st != noErr || !sampleBuf) {
        [_lock unlock];
        return NO;
    }

    VTDecodeFrameFlags flags = 0; // Synchronous low-latency decode!
    VTDecodeInfoFlags outFlags = 0;
    st = VTDecompressionSessionDecodeFrame(_session, sampleBuf, flags, NULL, &outFlags);
    CFRelease(sampleBuf);

    if (st == kVTInvalidSessionErr || st == kVTVideoDecoderMalfunctionErr) {
        // App returned from background -> re-create session cleanly on next config
        [self resetLocked];
        [_lock unlock];
        return NO;
    }
    [_lock unlock];
    return (st == noErr);
}

@end
