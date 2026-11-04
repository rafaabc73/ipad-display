#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <unistd.h>
#include <signal.h>
#include <sys/uio.h>

// Definições de API privada CGVirtualDisplay (macOS Sonoma)
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic, retain) dispatch_queue_t queue;
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

@interface DisplayController : NSObject <SCStreamOutput>
@property (nonatomic, strong) CGVirtualDisplay *virtualDisplay;
@property (nonatomic, strong) SCStream *currentStream;
@property (nonatomic, copy) NSString *currentMode;
@property (nonatomic) CGDirectDisplayID currentDisplayID;
@property (nonatomic) CGRect currentBounds;
@property (nonatomic, strong) dispatch_queue_t streamQueue;
@property (nonatomic, strong) dispatch_queue_t outputQueue;
@property (atomic) BOOL isCapturing;
@property (atomic) BOOL isEncoding;
@property (atomic) BOOL isWriting;
@property (nonatomic) float compressionQuality;
@property (nonatomic) int targetFPS;
@property (nonatomic) int captureWidth;
@property (nonatomic) int captureHeight;
@property (atomic) BOOL switching;
@property (atomic) NSUInteger generation;
@property (nonatomic) CFTimeInterval lastFrameTime;
@property (nonatomic, strong) dispatch_source_t heartbeatTimer;
@end

@implementation DisplayController

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentMode = @"none";
        _currentDisplayID = CGMainDisplayID();
        _currentBounds = CGDisplayBounds(_currentDisplayID);
        _streamQueue = dispatch_queue_create("sc_stream_capture_queue", DISPATCH_QUEUE_SERIAL);
        _outputQueue = dispatch_queue_create("sc_stream_output_queue", DISPATCH_QUEUE_SERIAL);
        _isCapturing = NO;
        _isEncoding = NO;
        _isWriting = NO;
        _compressionQuality = 0.55; // Qualidade HD Retina otimizada (texto nítido sem artefatos e decodificação rápida)
        _targetFPS = 30;            // 30 FPS perfeitos sem acúmulo de fila
        _captureWidth = 1280;       // 1280x960 nativo 4:3 do iPad 4 (alta definição real)
        _captureHeight = 960;
        _lastFrameTime = 0;
        [self startHeartbeat];
    }
    return self;
}

- (void)startHeartbeat {
    if (self.heartbeatTimer) return;
    self.heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.streamQueue);
    dispatch_source_set_timer(self.heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 33 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.heartbeatTimer, ^{
        DisplayController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isCapturing) return;
        
        CFTimeInterval now = CACurrentMediaTime();
        // Envia frame se o display estiver com conteúdo estático
        if (now - strongSelf.lastFrameTime >= 0.033) {
            [strongSelf captureAndSendImmediateFrame];
        }
    });
    dispatch_resume(self.heartbeatTimer);
}

- (void)ensureVirtualDisplay {
    if (self.virtualDisplay != nil) return;
    
    fprintf(stderr, "[Core] Criando monitor virtual independente (4:3 Retina)...\n");
    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.name = @"iPad Display";
    descriptor.maxPixelsWide = 2560;
    descriptor.maxPixelsHigh = 1920;
    descriptor.sizeInMillimeters = CGSizeMake(200, 150);
    descriptor.queue = dispatch_get_main_queue();

    self.virtualDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    CGVirtualDisplayMode *mode1 = [[CGVirtualDisplayMode alloc] initWithWidth:1280 height:960 refreshRate:60.0];
    CGVirtualDisplayMode *mode2 = [[CGVirtualDisplayMode alloc] initWithWidth:1600 height:1200 refreshRate:60.0];
    CGVirtualDisplayMode *mode3 = [[CGVirtualDisplayMode alloc] initWithWidth:1024 height:768 refreshRate:60.0];
    
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.modes = @[mode1, mode2, mode3];
    settings.hiDPI = 0;

    [self.virtualDisplay applySettings:settings];
    fprintf(stderr, "[Core] Monitor virtual criado! Display ID: %u\n", self.virtualDisplay.displayID);

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];

    // CONFIGURAÇÃO EXPLÍCITA: Desativa espelhamento para ser SEGUNDA TELA genuína
    CGDisplayConfigRef configRef;
    if (CGBeginDisplayConfiguration(&configRef) == kCGErrorSuccess) {
        CGConfigureDisplayMirrorOfDisplay(configRef, self.virtualDisplay.displayID, kCGNullDirectDisplay);
        
        CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
        CGConfigureDisplayOrigin(configRef, self.virtualDisplay.displayID, 
                                 (int)(mainBounds.origin.x + mainBounds.size.width), 
                                 (int)mainBounds.origin.y);
        
        CGCompleteDisplayConfiguration(configRef, kCGConfigurePermanently);
        fprintf(stderr, "[Core] Monitor configurado como SEGUNDA TELA ESTENDIDA à direita do Mac!\n");
    }
}

- (void)destroyVirtualDisplay {
    if (self.virtualDisplay != nil) {
        fprintf(stderr, "[Core] Destruindo monitor virtual...\n");
        self.virtualDisplay = nil;
    }
}

// Localiza o display alvo aguardando o WindowServer registrá-lo
- (void)findTargetDisplayWithCompletion:(void (^)(SCDisplay *targetDisplay))completion {
    BOOL needVirtual = [self.currentMode isEqualToString:@"second"];
    CGDirectDisplayID targetID = needVirtual ? (self.virtualDisplay ? self.virtualDisplay.displayID : 0) : CGMainDisplayID();

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *sc, NSError *err) {
        if (err || !sc || sc.displays.count == 0) {
            if (completion) completion(nil);
            return;
        }

        SCDisplay *found = nil;
        for (SCDisplay *d in sc.displays) {
            if (d.displayID == targetID) {
                found = d;
                break;
            }
        }

        if (found) {
            if (completion) completion(found);
        } else if (needVirtual) {
            // Se precisamos do virtual mas ainda não apareceu na lista, aguarda 200ms
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self findTargetDisplayWithCompletion:completion];
            });
        } else {
            if (completion) completion(sc.displays.firstObject);
        }
    }];
}

- (void)switchMode:(NSString *)mode completion:(void (^)(BOOL success))completion {
    if ([self.currentMode isEqualToString:mode] && self.isCapturing && !self.switching) {
        if (completion) completion(YES);
        return;
    }
    self.switching = YES;
    NSUInteger myGen = ++self.generation;

    fprintf(stderr, "[Core] Alternando para modo: %s\n", [mode UTF8String]);

    if (self.currentStream != nil) {
        SCStream *oldStream = self.currentStream;
        self.currentStream = nil;
        [oldStream stopCaptureWithCompletionHandler:nil];
    }

    self.currentMode = mode;
    self.isEncoding = NO;

    if ([mode isEqualToString:@"stop"]) {
        self.isCapturing = NO;
        self.switching = NO;
        if (completion) completion(YES);
        return;
    }

    BOOL needVirtual = [mode isEqualToString:@"second"];
    if (needVirtual) {
        [self ensureVirtualDisplay];
    }

    [self findTargetDisplayWithCompletion:^(SCDisplay *targetDisplay) {
        if (myGen != self.generation) { return; }
        if (!targetDisplay) {
            self.switching = NO;
            fprintf(stderr, "[Core] Erro: display alvo não encontrado.\n");
            if (completion) completion(NO);
            return;
        }

        if (needVirtual) {
            if (self.captureWidth <= 0 || self.captureHeight <= 0) {
                self.captureWidth = 1280;
                self.captureHeight = 960;
            }
        } else {
            if (self.captureWidth <= 0 || self.captureHeight <= 0) {
                self.captureWidth = 1440;
                self.captureHeight = 900;
            }
        }

        self.currentDisplayID = targetDisplay.displayID;
        self.currentBounds = CGDisplayBounds(self.currentDisplayID);
        if (self.currentBounds.size.width <= 1 || self.currentBounds.size.height <= 1) {
            self.currentBounds = CGRectMake(self.currentBounds.origin.x, self.currentBounds.origin.y, self.captureWidth, self.captureHeight);
        }
        fprintf(stderr, "[Core] Capturando display ID: %u (%ldx%ld) com saída %dx%d a %d FPS (Qualidade: %.2f)\n", 
                self.currentDisplayID, (long)targetDisplay.width, (long)targetDisplay.height,
                self.captureWidth, self.captureHeight, self.targetFPS, self.compressionQuality);

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = self.captureWidth;
        config.height = self.captureHeight;
        config.minimumFrameInterval = CMTimeMake(1, self.targetFPS);
        config.queueDepth = 1;
        config.showsCursor = YES;

        self.currentStream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
        NSError *addError = nil;
        [self.currentStream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.streamQueue error:&addError];
        if (addError) {
            fprintf(stderr, "[Core] Erro ao adicionar output: %s\n", [[addError localizedDescription] UTF8String]);
            self.switching = NO;
            if (completion) completion(NO);
            return;
        }

        [self.currentStream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
            if (startError) {
                fprintf(stderr, "[Core] Erro ao iniciar captura: %s\n", [[startError localizedDescription] UTF8String]);
                self.isCapturing = NO;
                self.switching = NO;
                if (completion) completion(NO);
            } else {
                fprintf(stderr, "[Core] Captura iniciada com sucesso em Alta Definição!\n");
                self.isCapturing = YES;
                self.switching = NO;
                // Envia imediatamente o frame inicial correto
                [self captureAndSendImmediateFrame];
                if (completion) completion(YES);
            }
        }];
    }];
}

- (void)captureAndSendImmediateFrame {
    if (!self.isCapturing) return;
    if (self.isEncoding) return;
    self.isEncoding = YES;

    CGDirectDisplayID dID = self.currentDisplayID;
    if (dID == 0) {
        self.isEncoding = NO;
        return;
    }

    @autoreleasepool {
        CGImageRef cgImage = CGDisplayCreateImage(dID);
        if (!cgImage) {
            self.isEncoding = NO;
            return;
        }

        size_t srcW = CGImageGetWidth(cgImage);
        size_t srcH = CGImageGetHeight(cgImage);
        size_t targetW = (self.captureWidth > 0) ? self.captureWidth : srcW;
        size_t targetH = (self.captureHeight > 0) ? self.captureHeight : srcH;

        // Verifica se o ponteiro do mouse está na área deste monitor
        BOOL mouseOnScreen = NO;
        CGPoint mousePos = CGPointZero;
        CGEventRef ev = CGEventCreate(NULL);
        if (ev) {
            mousePos = CGEventGetLocation(ev);
            CFRelease(ev);
            mouseOnScreen = CGRectContainsPoint(self.currentBounds, mousePos);
        }

        // Se a resolução for 1:1 e o mouse NÃO estiver nesta tela, usa cgImage direto com nitidez pura
        if (srcW == targetW && srcH == targetH && !mouseOnScreen) {
            // Imagem 100% nativa sem recompressão de contexto
        } else {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(NULL, targetW, targetH, 8, targetW * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
            CGColorSpaceRelease(cs);
            if (ctx) {
                // Interpolação de Alta Qualidade para manter o texto 100% nítido
                CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
                CGContextDrawImage(ctx, CGRectMake(0, 0, targetW, targetH), cgImage);

                if (mouseOnScreen) {
                    CGFloat scaleX = (CGFloat)targetW / self.currentBounds.size.width;
                    CGFloat scaleY = (CGFloat)targetH / self.currentBounds.size.height;
                    CGFloat localX = (mousePos.x - self.currentBounds.origin.x) * scaleX;
                    CGFloat localY = (self.currentBounds.size.height - (mousePos.y - self.currentBounds.origin.y)) * scaleY;

                    CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 1.0);
                    CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 1.0);
                    CGContextSetLineWidth(ctx, 2.0);

                    CGMutablePathRef path = CGPathCreateMutable();
                    CGPathMoveToPoint(path, NULL, localX, localY);
                    CGPathAddLineToPoint(path, NULL, localX, localY - 20);
                    CGPathAddLineToPoint(path, NULL, localX + 5, localY - 15);
                    CGPathAddLineToPoint(path, NULL, localX + 10, localY - 24);
                    CGPathAddLineToPoint(path, NULL, localX + 13, localY - 22);
                    CGPathAddLineToPoint(path, NULL, localX + 9, localY - 14);
                    CGPathAddLineToPoint(path, NULL, localX + 15, localY - 14);
                    CGPathCloseSubpath(path);

                    CGContextAddPath(ctx, path);
                    CGContextDrawPath(ctx, kCGPathFillStroke);
                    CGPathRelease(path);
                }

                CGImageRef scaledImage = CGBitmapContextCreateImage(ctx);
                CGContextRelease(ctx);
                CGImageRelease(cgImage);
                cgImage = scaledImage;
            }
        }

        NSMutableData *jpegData = [NSMutableData data];
        CGImageDestinationRef dest = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)jpegData, 
            (__bridge CFStringRef)UTTypeJPEG.identifier, 
            1, 
            NULL
        );

        if (dest) {
            NSDictionary *options = @{
                (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(self.compressionQuality)
            };
            CGImageDestinationAddImage(dest, cgImage, (__bridge CFDictionaryRef)options);
            CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        if (cgImage) {
            CGImageRelease(cgImage);
        }

        if (jpegData.length > 0) {
            self.lastFrameTime = CACurrentMediaTime();
            [self sendJpegData:jpegData];
        }
    }
    self.isEncoding = NO;
}

- (void)sendJpegData:(NSData *)jpegData {
    if (!jpegData || jpegData.length == 0) return;
    if (self.isWriting) return;
    self.isWriting = YES;

    dispatch_async(self.outputQueue, ^{
        @try {
            uint8_t header[8] = {'I', 'P', 'A', 'D', 0, 0, 0, 0};
            uint32_t len = CFSwapInt32HostToBig((uint32_t)jpegData.length);
            memcpy(&header[4], &len, 4);

            struct iovec iov[2];
            iov[0].iov_base = header;
            iov[0].iov_len = 8;
            iov[1].iov_base = (void *)jpegData.bytes;
            iov[1].iov_len = jpegData.length;

            writev(STDOUT_FILENO, iov, 2);
        } @finally {
            self.isWriting = NO;
        }
    });
}

- (void)handleClickAtNormalizedX:(float)normX normalizedY:(float)normY {
    CGRect bounds = CGDisplayBounds(self.currentDisplayID);
    if (bounds.size.width <= 1 || bounds.size.height <= 1) {
        bounds = self.currentBounds;
    }
    CGFloat x = bounds.origin.x + (normX * bounds.size.width);
    CGFloat y = bounds.origin.y + (normY * bounds.size.height);
    CGPoint pt = CGPointMake(x, y);

    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, pt, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, move);
    CFRelease(move);

    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, pt, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, down);
    CFRelease(down);

    usleep(10000); // 10ms click duration

    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, pt, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(up);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self captureAndSendImmediateFrame];
    });
}

- (void)handleMoveAtNormalizedX:(float)normX normalizedY:(float)normY {
    CGRect bounds = CGDisplayBounds(self.currentDisplayID);
    if (bounds.size.width <= 1 || bounds.size.height <= 1) {
        bounds = self.currentBounds;
    }
    CGFloat x = bounds.origin.x + (normX * bounds.size.width);
    CGFloat y = bounds.origin.y + (normY * bounds.size.height);
    CGPoint pt = CGPointMake(x, y);

    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, pt, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, move);
    CFRelease(move);
}

// Callback de saída do ScreenCaptureKit
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !self.isCapturing) return;

    if (self.isEncoding) {
        return;
    }
    self.isEncoding = YES;

    @autoreleasepool {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) {
            self.isEncoding = NO;
            return;
        }

        CGImageRef cgImage = NULL;
        OSStatus status = VTCreateCGImageFromCVPixelBuffer(imageBuffer, NULL, &cgImage);
        if (status != noErr || !cgImage) {
            self.isEncoding = NO;
            return;
        }

        NSMutableData *jpegData = [NSMutableData data];
        CGImageDestinationRef dest = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)jpegData, 
            (__bridge CFStringRef)UTTypeJPEG.identifier, 
            1, 
            NULL
        );

        if (dest) {
            NSDictionary *options = @{
                (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(self.compressionQuality)
            };
            CGImageDestinationAddImage(dest, cgImage, (__bridge CFDictionaryRef)options);
            CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        CGImageRelease(cgImage);

        if (jpegData.length > 0) {
            self.lastFrameTime = CACurrentMediaTime();
            [self sendJpegData:jpegData];
        }
    }

    self.isEncoding = NO;
}

@end

static DisplayController *gController = nil;

void sigHandler(int sig) {
    fprintf(stderr, "\n[Core] Finalizando e limpando recursos...\n");
    if (gController) {
        [gController destroyVirtualDisplay];
    }
    exit(0);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        signal(SIGINT, sigHandler);
        signal(SIGTERM, sigHandler);
        signal(SIGPIPE, SIG_IGN);

        gController = [[DisplayController alloc] init];

        NSString *initialMode = @"second"; // Inicia diretamente em modo segunda tela
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
                initialMode = [NSString stringWithUTF8String:argv[++i]];
            } else if (strcmp(argv[i], "--quality") == 0 && i + 1 < argc) {
                gController.compressionQuality = atof(argv[++i]);
            } else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
                gController.targetFPS = atoi(argv[++i]);
            }
        }

        fprintf(stderr, "[Core] iPad Display Core iniciado a %d FPS (Qualidade: %.2f). Modo inicial: %s\n", 
                gController.targetFPS, gController.compressionQuality, [initialMode UTF8String]);
        [gController switchMode:initialMode completion:nil];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            char buffer[512];
            while (fgets(buffer, sizeof(buffer), stdin) != NULL) {
                NSString *line = [[NSString stringWithUTF8String:buffer] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([line hasPrefix:@"MODE "]) {
                    NSString *m = [line substringFromIndex:5];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [gController switchMode:m completion:nil];
                    });
                } else if ([line hasPrefix:@"QUALITY "]) {
                    float q = [[line substringFromIndex:8] floatValue];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        gController.compressionQuality = q;
                        fprintf(stderr, "[Core] Qualidade ajustada para: %.2f\n", q);
                    });
                } else if ([line hasPrefix:@"FPS "]) {
                    int fps = [[line substringFromIndex:4] intValue];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (fps > 0 && fps != gController.targetFPS) {
                            gController.targetFPS = fps;
                            NSString *cm = gController.currentMode;
                            gController.currentMode = @"none";
                            [gController switchMode:cm completion:nil];
                            fprintf(stderr, "[Core] FPS ajustado para: %d\n", fps);
                        }
                    });
                } else if ([line hasPrefix:@"RES "]) {
                    NSArray *parts = [line componentsSeparatedByString:@" "];
                    if (parts.count >= 3) {
                        int w = [parts[1] intValue];
                        int h = [parts[2] intValue];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (w > 0 && h > 0 && (w != gController.captureWidth || h != gController.captureHeight)) {
                                gController.captureWidth = w;
                                gController.captureHeight = h;

                                if (gController.virtualDisplay != nil) {
                                    CGVirtualDisplayMode *newMode = [[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60.0];
                                    CGVirtualDisplaySettings *s = [[CGVirtualDisplaySettings alloc] init];
                                    s.modes = @[newMode];
                                    s.hiDPI = 0;
                                    [gController.virtualDisplay applySettings:s];
                                    fprintf(stderr, "[Core] Monitor virtual redimensionado para: %dx%d\n", w, h);
                                }

                                NSString *cm = gController.currentMode;
                                gController.currentMode = @"none";
                                [gController switchMode:cm completion:nil];
                                fprintf(stderr, "[Core] Resolução alterada para: %dx%d\n", w, h);
                            }
                        });
                    }
                } else if ([line hasPrefix:@"CLICK "]) {
                    NSArray *parts = [line componentsSeparatedByString:@" "];
                    if (parts.count >= 3) {
                        float x = [parts[1] floatValue];
                        float y = [parts[2] floatValue];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [gController handleClickAtNormalizedX:x normalizedY:y];
                        });
                    }
                } else if ([line hasPrefix:@"MOVE "]) {
                    NSArray *parts = [line componentsSeparatedByString:@" "];
                    if (parts.count >= 3) {
                        float x = [parts[1] floatValue];
                        float y = [parts[2] floatValue];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [gController handleMoveAtNormalizedX:x normalizedY:y];
                        });
                    }
                } else if ([line isEqualToString:@"QUIT"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        sigHandler(0);
                    });
                    break;
                }
            }
        });

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
