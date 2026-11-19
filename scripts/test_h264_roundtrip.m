#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <math.h>
#include <stdio.h>

static int gDecodedCount = 0;
static int gDecodeErrors = 0;
static double gMinPSNR = 999.0;
static double gSumPSNR = 0.0;
static size_t gSumBytes = 0;
static size_t gMaxBytes = 0;
static VTDecompressionSessionRef gDecSess = NULL;
static CMVideoFormatDescriptionRef gDecFmt = NULL;
static VTPixelTransferSessionRef gDecToBGRA = NULL;
static CVPixelBufferPoolRef gBGRAPool = NULL;
static BOOL gSavedSample = NO;

static double compute_psnr(CVPixelBufferRef refPB, CVPixelBufferRef decPB) {
    CVPixelBufferLockBaseAddress(refPB, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(decPB, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(decPB);
    size_t h = CVPixelBufferGetHeight(decPB);
    const uint8_t *rBase = CVPixelBufferGetBaseAddress(refPB);
    const uint8_t *dBase = CVPixelBufferGetBaseAddress(decPB);
    size_t rStride = CVPixelBufferGetBytesPerRow(refPB);
    size_t dStride = CVPixelBufferGetBytesPerRow(decPB);

    double mse = 0.0;
    size_t count = 0;
    for (size_t y = 0; y < h; y += 2) {
        const uint8_t *rr = rBase + y * rStride;
        const uint8_t *dd = dBase + y * dStride;
        for (size_t x = 0; x < w; x += 2) {
            for (int c = 0; c < 3; c++) {
                double diff = (double)rr[x*4 + c] - (double)dd[x*4 + c];
                mse += diff * diff;
                count++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(decPB, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(refPB, kCVPixelBufferLock_ReadOnly);
    mse /= (double)count;
    if (mse < 1e-6) return 99.0;
    return 10.0 * log10((255.0 * 255.0) / mse);
}

static void save_pb_png(CVPixelBufferRef pb, const char *path) {
    CGImageRef img = NULL;
    if (VTCreateCGImageFromCVPixelBuffer(pb, NULL, &img) != noErr || !img) return;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, img, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(img);
}

static void decodeCallback(void *ref, void *srcRef, OSStatus st, VTDecodeInfoFlags flags,
                           CVImageBufferRef pb, CMTime pts, CMTime dur) {
    CVPixelBufferRef refBGRA = (CVPixelBufferRef)srcRef;
    if (st != noErr || !pb) {
        gDecodeErrors++;
        printf("  [ERROR] VTDecompressionSession decode callback status=%d\n", (int)st);
        if (refBGRA) CVPixelBufferRelease(refBGRA);
        return;
    }
    CVPixelBufferRef bgra = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, gBGRAPool, &bgra) == kCVReturnSuccess && bgra) {
        VTPixelTransferSessionTransferImage(gDecToBGRA, pb, bgra);
        gDecodedCount++;
        if (refBGRA) {
            double psnr = compute_psnr(refBGRA, bgra);
            if (psnr < gMinPSNR) gMinPSNR = psnr;
            gSumPSNR += psnr;
        }
        if (gDecodedCount == 15 && !gSavedSample) {
            gSavedSample = YES;
            save_pb_png(bgra, "/tmp/h264_roundtrip_frame15.png");
        }
        CVPixelBufferRelease(bgra);
    }
    if (refBGRA) CVPixelBufferRelease(refBGRA);
}

static void encodeCallback(void *ref, void *srcRef, OSStatus st, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    CVPixelBufferRef refBGRA = (CVPixelBufferRef)srcRef;
    if (st != noErr || !sb) {
        gDecodeErrors++;
        if (refBGRA) CVPixelBufferRelease(refBGRA);
        return;
    }

    // Recreate decoder on keyframe SPS/PPS exactly like iPad VideoDecoder.m!
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!gDecSess && fmt) {
        const uint8_t *sps = NULL, *pps = NULL;
        size_t spsLen = 0, ppsLen = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &spsLen, NULL, NULL) == noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &ppsLen, NULL, NULL) == noErr) {
            const uint8_t *sets[2] = { sps, pps };
            const size_t lens[2] = { spsLen, ppsLen };
            CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, lens, 4, &gDecFmt);
            NSDictionary *destAttrs = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
            };
            VTDecompressionOutputCallbackRecord cb = { decodeCallback, NULL };
            OSStatus dst = VTDecompressionSessionCreate(NULL, gDecFmt, NULL, (__bridge CFDictionaryRef)destAttrs, &cb, &gDecSess);
            if (dst != noErr) {
                gDecodeErrors++;
                if (refBGRA) CVPixelBufferRelease(refBGRA);
                return;
            }
        }
    }

    if (!gDecSess || !gDecFmt) {
        gDecodeErrors++;
        if (refBGRA) CVPixelBufferRelease(refBGRA);
        return;
    }

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = CMBlockBufferGetDataLength(bb);
    gSumBytes += len;
    if (len > gMaxBytes) gMaxBytes = len;

    void *copyBuf = malloc(len);
    CMBlockBufferCopyDataBytes(bb, 0, len, copyBuf);

    CMBlockBufferRef newBB = NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL, copyBuf, len, kCFAllocatorMalloc, NULL, 0, len, 0, &newBB);
    CMSampleBufferRef decSB = NULL;
    const size_t szArr[1] = { len };
    CMSampleTimingInfo ti = { CMTimeMake(1, 60), CMSampleBufferGetPresentationTimeStamp(sb), kCMTimeInvalid };
    CMSampleBufferCreateReady(NULL, newBB, gDecFmt, 1, 1, &ti, 1, szArr, &decSB);
    CFRelease(newBB);

    VTDecodeInfoFlags outFlags = 0;
    // Pass refBGRA ownership into decodeCallback for exact frame-to-frame PSNR!
    OSStatus decSt = VTDecompressionSessionDecodeFrame(gDecSess, decSB, 0, refBGRA, &outFlags);
    CFRelease(decSB);
    if (decSt != noErr) {
        gDecodeErrors++;
        if (refBGRA) CVPixelBufferRelease(refBGRA);
    }
}

int main() {
    @autoreleasepool {
        int srcW = 2048, srcH = 1536;
        int vidW = 1280, vidH = 960; // Exact 4:3, A6X Level 4.1 60 FPS safe!

        NSDictionary *encSpec = @{ (id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES };
        NSDictionary *nv12Attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(vidW),
            (id)kCVPixelBufferHeightKey: @(vidH),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        NSDictionary *bgraAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(vidW),
            (id)kCVPixelBufferHeightKey: @(vidH),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };

        VTCompressionSessionRef enc = NULL;
        OSStatus st = VTCompressionSessionCreate(NULL, vidW, vidH, kCMVideoCodecType_H264,
                                                 (__bridge CFDictionaryRef)encSpec,
                                                 (__bridge CFDictionaryRef)nv12Attrs,
                                                 NULL, encodeCallback, NULL, &enc);
        if (st != noErr) { printf("Enc create failed %d\n", (int)st); return 1; }
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_4_1);
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_MaxFrameDelayCount, (__bridge CFTypeRef)@(0));
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(60));
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(60));
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(14000000));
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFTypeRef)@[ @(2200000), @(1.0) ]);
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
        VTSessionSetProperty(enc, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
        VTCompressionSessionPrepareToEncodeFrames(enc);

        VTPixelTransferSessionRef xfer = NULL;
        VTPixelTransferSessionCreate(NULL, &xfer);
        VTSessionSetProperty(xfer, kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
        VTSessionSetProperty(xfer, kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
        VTSessionSetProperty(xfer, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);

        VTPixelTransferSessionCreate(NULL, &gDecToBGRA);
        CVPixelBufferPoolRef nv12Pool = NULL;
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)nv12Attrs, &nv12Pool);
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)bgraAttrs, &gBGRAPool);

        // Pre-render 30 moving browser-window frames so timing measures pure HW H.264 encode+decode!
        const int N = 30;
        CVPixelBufferRef srcFrames[N];
        CVPixelBufferRef refFrames[N];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        for (int f = 0; f < N; f++) {
            srcFrames[f] = NULL;
            refFrames[f] = NULL;
            CVPixelBufferCreate(NULL, srcW, srcH, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &srcFrames[f]);
            CVPixelBufferPoolCreatePixelBuffer(NULL, gBGRAPool, &refFrames[f]);

            CVPixelBufferLockBaseAddress(srcFrames[f], 0);
            CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(srcFrames[f]), srcW, srcH, 8,
                                                     CVPixelBufferGetBytesPerRow(srcFrames[f]), cs,
                                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGContextSetRGBFillColor(ctx, 0.12, 0.16, 0.24, 1.0);
            CGContextFillRect(ctx, CGRectMake(0, 0, srcW, srcH));
            CGFloat wx = 120.0 + f * 18.0;
            CGFloat wy = 180.0 + sin(f * 0.25) * 60.0;
            CGContextSetRGBFillColor(ctx, 0.96, 0.97, 0.99, 1.0);
            CGContextFillRect(ctx, CGRectMake(wx, wy, 1280, 900));
            CGContextSetRGBFillColor(ctx, 0.86, 0.88, 0.92, 1.0);
            CGContextFillRect(ctx, CGRectMake(wx, wy + 820, 1280, 80));
            CGContextSetRGBFillColor(ctx, 0.0, 0.45, 0.90, 1.0);
            CGContextFillRect(ctx, CGRectMake(wx + 24 + (f % 3) * 200, wy + 830, 180, 60));
            CGContextSetRGBFillColor(ctx, 0.15, 0.15, 0.18, 1.0);
            for (int r = 0; r < 18; r++) {
                CGContextFillRect(ctx, CGRectMake(wx + 40, wy + 60 + r * 40, 400 + ((r * 97) % 700), 14));
            }
            CGContextRelease(ctx);
            CVPixelBufferUnlockBaseAddress(srcFrames[f], 0);

            VTPixelTransferSessionTransferImage(xfer, srcFrames[f], refFrames[f]);
        }

        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        for (int f = 0; f < N; f++) {
            CVPixelBufferRef nv12 = NULL;
            CVPixelBufferPoolCreatePixelBuffer(NULL, nv12Pool, &nv12);
            CVBufferSetAttachment(nv12, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(nv12, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(nv12, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            VTPixelTransferSessionTransferImage(xfer, srcFrames[f], nv12);

            NSDictionary *fProps = (f == 0) ? @{ (id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES } : nil;
            CVPixelBufferRetain(refFrames[f]);
            VTCompressionSessionEncodeFrame(enc, nv12, CMTimeMake(f, 60), CMTimeMake(1, 60),
                                            (__bridge CFDictionaryRef)fProps, refFrames[f], NULL);
            CVPixelBufferRelease(nv12);
        }
        VTCompressionSessionCompleteFrames(enc, kCMTimeInvalid);
        double dt = CFAbsoluteTimeGetCurrent() - t0;

        for (int f = 0; f < N; f++) {
            CVPixelBufferRelease(srcFrames[f]);
            CVPixelBufferRelease(refFrames[f]);
        }

        double avgPSNR = gDecodedCount > 0 ? gSumPSNR / gDecodedCount : 0.0;
        double avgKB = gDecodedCount > 0 ? (double)gSumBytes / gDecodedCount / 1024.0 : 0.0;
        printf("✓ H.264 Round-Trip (%dx%d): decoded=%d/%d errors=%d | avgPSNR=%.1f dB minPSNR=%.1f dB | avg=%.1fKB max=%.1fKB | %.1f FPS\n",
               vidW, vidH, gDecodedCount, N, gDecodeErrors, avgPSNR, gMinPSNR, avgKB, gMaxBytes / 1024.0, gDecodedCount / dt);

        CGColorSpaceRelease(cs);
        if (gDecodedCount < N || gDecodeErrors > 0 || gMinPSNR < 34.0) {
            printf("✗ H.264 QUALITY GATE FAILED!\n");
            return 2;
        }
        return 0;
    }
}
