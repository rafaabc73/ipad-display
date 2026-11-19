#import "GLDisplayView.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import "../shared/lz4/lz4.h"
#include <stdlib.h>
#include <string.h>

@interface DecodedTile : NSObject
@property (nonatomic) uint16_t x;
@property (nonatomic) uint16_t y;
@property (nonatomic) uint16_t w;
@property (nonatomic) uint16_t h;
@property (nonatomic, strong) NSData *pixels;
@end
@implementation DecodedTile
@end

@interface GLDisplayView () {
    CAEAGLLayer *_eaglLayer;
    EAGLContext *_context;
    GLuint _framebuffer;
    GLuint _colorRenderbuffer;
    GLint _backingWidth;
    GLint _backingHeight;

    GLuint _bgraProgram;
    GLuint _yuvProgram;
    GLuint _cursorProgram;
    GLuint _quadVBO;

    GLint _bgraLocScale, _bgraLocOffset, _bgraLocTex;
    GLint _yuvLocScale, _yuvLocOffset, _yuvLocY, _yuvLocUV;
    GLint _curLocScale, _curLocOffset, _curLocTex;

    GLuint _retinaTex;
    GLuint _cursorTex;
    uint16_t _retinaW;
    uint16_t _retinaH;

    CVOpenGLESTextureCacheRef _textureCache;
    CVOpenGLESTextureRef _lumaTexture;
    CVOpenGLESTextureRef _chromaTexture;
    uint16_t _videoW;
    uint16_t _videoH;

    BOOL _showVideoLayer;
    BOOL _hasRetinaContent;
    BOOL _hasVideoContent;
    BOOL _needsResize;

    float _cursorX;
    float _cursorY;
    BOOL _cursorVisible;

    dispatch_queue_t _decodeQueue;
}
@property (nonatomic, readwrite) CGRect activeImageRectInPoints;
@end

static GLuint compile_shader(GLenum type, const char *src) {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, NULL);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char logBuf[512];
        glGetShaderInfoLog(sh, sizeof(logBuf), NULL, logBuf);
        NSLog(@"[GLDisplayView] Shader compile error: %s", logBuf);
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

static GLuint link_program(const char *vsSrc, const char *fsSrc) {
    GLuint vs = compile_shader(GL_VERTEX_SHADER, vsSrc);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fsSrc);
    if (!vs || !fs) return 0;
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glBindAttribLocation(prog, 0, "aPos");
    glBindAttribLocation(prog, 1, "aTex");
    glLinkProgram(prog);
    GLint linked = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &linked);
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (!linked) {
        NSLog(@"[GLDisplayView] Program link error");
        glDeleteProgram(prog);
        return 0;
    }
    return prog;
}

@implementation GLDisplayView

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = YES;
        self.backgroundColor = [UIColor blackColor];
        self.contentScaleFactor = [UIScreen mainScreen].scale;

        _eaglLayer = (CAEAGLLayer *)self.layer;
        _eaglLayer.opaque = YES;
        _eaglLayer.contentsScale = self.contentScaleFactor;
        _eaglLayer.drawableProperties = @{
            kEAGLDrawablePropertyRetainedBacking: @NO,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        };

        _decodeQueue = dispatch_queue_create("ipd2.ios.decode", DISPATCH_QUEUE_SERIAL);
        _activeImageRectInPoints = frame;
        _needsResize = YES;

        [self setupGLOnMain];
    }
    return self;
}

- (void)dealloc {
    [self teardownGL];
}

- (uint16_t)retinaWidth { return _retinaW; }
- (uint16_t)retinaHeight { return _retinaH; }
- (int)backingWidth { return (int)_backingWidth; }
- (int)backingHeight { return (int)_backingHeight; }

- (void)setFillScreen:(BOOL)fillScreen {
    _fillScreen = fillScreen;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self renderCurrentFrameOnMain];
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _eaglLayer.contentsScale = [UIScreen mainScreen].scale;
    _needsResize = YES;
    [self rebuildRenderbufferOnMain];
    [self renderCurrentFrameOnMain];
}

// ALL OpenGL ES + CAEAGLLayer calls run strictly on the Main Thread per Apple CoreAnimation rules!
- (void)setupGLOnMain {
    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!_context || ![EAGLContext setCurrentContext:_context]) {
        NSLog(@"[GLDisplayView] Failed to create EAGLContext!");
        return;
    }

    glGenFramebuffers(1, &_framebuffer);
    glGenRenderbuffers(1, &_colorRenderbuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);

    static const GLfloat quadVerts[] = {
        -1.0f, -1.0f,  0.0f, 1.0f,
         1.0f, -1.0f,  1.0f, 1.0f,
        -1.0f,  1.0f,  0.0f, 0.0f,
         1.0f,  1.0f,  1.0f, 0.0f
    };
    glGenBuffers(1, &_quadVBO);
    glBindBuffer(GL_ARRAY_BUFFER, _quadVBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quadVerts), quadVerts, GL_STATIC_DRAW);

    const char *vs =
        "attribute vec2 aPos;"
        "attribute vec2 aTex;"
        "uniform vec2 uScale;"
        "uniform vec2 uOffset;"
        "varying vec2 vTex;"
        "void main() {"
        "  vTex = aTex;"
        "  gl_Position = vec4(aPos * uScale + uOffset, 0.0, 1.0);"
        "}";

    const char *fsBGRA =
        "precision mediump float;"
        "varying vec2 vTex;"
        "uniform sampler2D uTex;"
        "void main() {"
        "  vec4 c = texture2D(uTex, vTex);"
        "  gl_FragColor = vec4(c.b, c.g, c.r, 1.0);"
        "}";

    const char *fsYUV =
        "precision mediump float;"
        "varying vec2 vTex;"
        "uniform sampler2D uY;"
        "uniform sampler2D uUV;"
        "void main() {"
        "  float y = (texture2D(uY, vTex).r - 0.062745) * 1.16438;"
        "  vec2 uv = texture2D(uUV, vTex).ra - vec2(0.5, 0.5);"
        "  float r = y + 1.79274 * uv.y;"
        "  float g = y - 0.21325 * uv.x - 0.53291 * uv.y;"
        "  float b = y + 2.11240 * uv.x;"
        "  gl_FragColor = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0);"
        "}";

    const char *fsCursor =
        "precision mediump float;"
        "varying vec2 vTex;"
        "uniform sampler2D uTex;"
        "void main() {"
        "  gl_FragColor = texture2D(uTex, vTex);"
        "}";

    _bgraProgram = link_program(vs, fsBGRA);
    _yuvProgram = link_program(vs, fsYUV);
    _cursorProgram = link_program(vs, fsCursor);

    if (_bgraProgram) {
        _bgraLocScale  = glGetUniformLocation(_bgraProgram, "uScale");
        _bgraLocOffset = glGetUniformLocation(_bgraProgram, "uOffset");
        _bgraLocTex    = glGetUniformLocation(_bgraProgram, "uTex");
    }
    if (_yuvProgram) {
        _yuvLocScale  = glGetUniformLocation(_yuvProgram, "uScale");
        _yuvLocOffset = glGetUniformLocation(_yuvProgram, "uOffset");
        _yuvLocY      = glGetUniformLocation(_yuvProgram, "uY");
        _yuvLocUV     = glGetUniformLocation(_yuvProgram, "uUV");
    }
    if (_cursorProgram) {
        _curLocScale  = glGetUniformLocation(_cursorProgram, "uScale");
        _curLocOffset = glGetUniformLocation(_cursorProgram, "uOffset");
        _curLocTex    = glGetUniformLocation(_cursorProgram, "uTex");
    }

    glGenTextures(1, &_retinaTex);
    glBindTexture(GL_TEXTURE_2D, _retinaTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    [self buildRetinaCursorTextureOnMain];
    CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_textureCache);
    NSLog(@"[GLDisplayView] OpenGL ES 2.0 initialized (programs: bgra=%u yuv=%u cur=%u)", _bgraProgram, _yuvProgram, _cursorProgram);
}

- (void)buildRetinaCursorTextureOnMain {
    const int cw = 40, ch = 56;
    uint8_t *buf = (uint8_t *)calloc(1, cw * ch * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, cw, ch, 8, cw * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (ctx) {
        CGContextTranslateCTM(ctx, 0, ch);
        CGContextScaleCTM(ctx, 1.0, -1.0);

        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, 3, 3);
        CGPathAddLineToPoint(path, NULL, 3, 43);
        CGPathAddLineToPoint(path, NULL, 13, 33);
        CGPathAddLineToPoint(path, NULL, 20, 49);
        CGPathAddLineToPoint(path, NULL, 26, 46);
        CGPathAddLineToPoint(path, NULL, 19, 30);
        CGPathAddLineToPoint(path, NULL, 32, 30);
        CGPathCloseSubpath(path);

        CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 1.0);
        CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 1.0);
        CGContextSetLineWidth(ctx, 3.2);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextAddPath(ctx, path);
        CGContextDrawPath(ctx, kCGPathFillStroke);
        CGPathRelease(path);
        CGContextRelease(ctx);
    }

    glGenTextures(1, &_cursorTex);
    glBindTexture(GL_TEXTURE_2D, _cursorTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, cw, ch, 0, GL_RGBA, GL_UNSIGNED_BYTE, buf);
    free(buf);
}

- (void)rebuildRenderbufferOnMain {
    if (!_context || !_eaglLayer) return;
    if (CGRectIsEmpty(_eaglLayer.bounds)) return;
    if (![EAGLContext setCurrentContext:_context]) return;

    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);
    BOOL ok = [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:_eaglLayer];
    if (ok) {
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorRenderbuffer);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status == GL_FRAMEBUFFER_COMPLETE && _backingWidth > 0 && _backingHeight > 0) {
            _needsResize = NO;
            NSLog(@"[GLDisplayView] Framebuffer OK: %dx%d", (int)_backingWidth, (int)_backingHeight);
        } else {
            NSLog(@"[GLDisplayView] Framebuffer incomplete: 0x%x (%dx%d)", status, (int)_backingWidth, (int)_backingHeight);
        }
    } else {
        NSLog(@"[GLDisplayView] renderbufferStorage:fromDrawable: FAILED!");
    }
}

- (void)releaseVideoTexturesOnMain {
    if (_lumaTexture) { CFRelease(_lumaTexture); _lumaTexture = NULL; }
    if (_chromaTexture) { CFRelease(_chromaTexture); _chromaTexture = NULL; }
    if (_textureCache) { CVOpenGLESTextureCacheFlush(_textureCache, 0); }
}

- (void)teardownGL {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self teardownGL]; });
        return;
    }
    if (_context) {
        [EAGLContext setCurrentContext:_context];
        [self releaseVideoTexturesOnMain];
        if (_textureCache) { CFRelease(_textureCache); _textureCache = NULL; }
        if (_retinaTex) { glDeleteTextures(1, &_retinaTex); _retinaTex = 0; }
        if (_cursorTex) { glDeleteTextures(1, &_cursorTex); _cursorTex = 0; }
        if (_quadVBO) { glDeleteBuffers(1, &_quadVBO); _quadVBO = 0; }
        if (_bgraProgram) { glDeleteProgram(_bgraProgram); _bgraProgram = 0; }
        if (_yuvProgram) { glDeleteProgram(_yuvProgram); _yuvProgram = 0; }
        if (_cursorProgram) { glDeleteProgram(_cursorProgram); _cursorProgram = 0; }
        if (_colorRenderbuffer) { glDeleteRenderbuffers(1, &_colorRenderbuffer); _colorRenderbuffer = 0; }
        if (_framebuffer) { glDeleteFramebuffers(1, &_framebuffer); _framebuffer = 0; }
        [EAGLContext setCurrentContext:nil];
        _context = nil;
    }
}

- (void)clearDisplay {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_hasRetinaContent = NO;
        self->_hasVideoContent = NO;
        self->_showVideoLayer = NO;
        self->_cursorVisible = NO;
        self->_retinaW = 0;
        self->_retinaH = 0;
        [self releaseVideoTexturesOnMain];
        if (!self->_context) return;
        [EAGLContext setCurrentContext:self->_context];
        if (self->_needsResize || self->_backingWidth <= 0) [self rebuildRenderbufferOnMain];
        if (self->_backingWidth <= 0 || self->_backingHeight <= 0) return;
        glBindFramebuffer(GL_FRAMEBUFFER, self->_framebuffer);
        glViewport(0, 0, self->_backingWidth, self->_backingHeight);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glBindRenderbuffer(GL_RENDERBUFFER, self->_colorRenderbuffer);
        [self->_context presentRenderbuffer:GL_RENDERBUFFER];
    });
}

// Decompress LZ4 tiles on background queue, upload & draw strictly on Main Thread!
- (void)applyTileBatchData:(NSData *)payload flags:(uint8_t)flags tileCount:(uint16_t)tileCount {
    if (!payload || payload.length < sizeof(IPD2TileBatchHeader)) return;
    if (flags & IPD2_TILE_FLAG_HALF_RES) return;

    dispatch_async(_decodeQueue, ^{
        const uint8_t *bytes = (const uint8_t *)payload.bytes;
        size_t totalLen = payload.length;
        IPD2TileBatchHeader bh;
        memcpy(&bh, bytes, sizeof(bh));

        NSMutableArray<DecodedTile *> *decoded = [NSMutableArray arrayWithCapacity:tileCount];
        size_t off = sizeof(IPD2TileBatchHeader);

        for (uint16_t i = 0; i < tileCount; i++) {
            if (off + sizeof(IPD2TileHeader) > totalLen) break;
            IPD2TileHeader th;
            memcpy(&th, bytes + off, sizeof(th));
            off += sizeof(IPD2TileHeader);
            if (off + th.dataLen > totalLen) break;

            size_t rawSize = (size_t)th.w * (size_t)th.h * 4;
            if (rawSize == 0 || (uint32_t)th.x + th.w > bh.frameW || (uint32_t)th.y + th.h > bh.frameH) {
                off += th.dataLen;
                continue;
            }

            if (th.encoding == IPD2_ENC_LZ4_BGRA) {
                NSMutableData *raw = [NSMutableData dataWithLength:rawSize];
                int dec = LZ4_decompress_safe((const char *)(bytes + off),
                                              (char *)raw.mutableBytes,
                                              (int)th.dataLen,
                                              (int)rawSize);
                if (dec == (int)rawSize) {
                    DecodedTile *t = [[DecodedTile alloc] init];
                    t.x = th.x; t.y = th.y; t.w = th.w; t.h = th.h;
                    t.pixels = raw;
                    [decoded addObject:t];
                }
            } else if (th.encoding == IPD2_ENC_RAW_BGRA && th.dataLen == rawSize) {
                DecodedTile *t = [[DecodedTile alloc] init];
                t.x = th.x; t.y = th.y; t.w = th.w; t.h = th.h;
                t.pixels = [NSData dataWithBytes:(bytes + off) length:rawSize];
                [decoded addObject:t];
            }
            off += th.dataLen;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_context) return;
            if (![EAGLContext setCurrentContext:self->_context]) return;
            if (self->_needsResize || self->_backingWidth <= 0) [self rebuildRenderbufferOnMain];

            glBindTexture(GL_TEXTURE_2D, self->_retinaTex);
            glPixelStorei(GL_UNPACK_ALIGNMENT, 4);

            if (bh.frameW > 0 && bh.frameH > 0 && (bh.frameW != self->_retinaW || bh.frameH != self->_retinaH)) {
                self->_retinaW = bh.frameW;
                self->_retinaH = bh.frameH;
                glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, self->_retinaW, self->_retinaH,
                             0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
                GLenum err = glGetError();
                NSLog(@"[GLDisplayView] Allocated Retina texture %ux%u (glErr=0x%x)", self->_retinaW, self->_retinaH, err);
            }

            for (DecodedTile *t in decoded) {
                glTexSubImage2D(GL_TEXTURE_2D, 0, t.x, t.y, t.w, t.h,
                                GL_RGBA, GL_UNSIGNED_BYTE, t.pixels.bytes);
            }

            self->_hasRetinaContent = YES;
            if ((flags & IPD2_TILE_FLAG_FULL_SYNC) || !self->_showVideoLayer) {
                self->_showVideoLayer = NO;
            }
            [self renderCurrentFrameOnMain];
        });
    });
}

- (void)displayH264PixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_context || !self->_textureCache) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        if (![EAGLContext setCurrentContext:self->_context]) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        if (self->_needsResize || self->_backingWidth <= 0) [self rebuildRenderbufferOnMain];

        [self releaseVideoTexturesOnMain];

        size_t w0 = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        size_t h0 = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        size_t w1 = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
        size_t h1 = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
        if (w0 == 0 || h0 == 0 || w1 == 0 || h1 == 0) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        self->_videoW = (uint16_t)w0;
        self->_videoH = (uint16_t)h0;

        glActiveTexture(GL_TEXTURE0);
        CVReturn r1 = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self->_textureCache, pixelBuffer, NULL,
            GL_TEXTURE_2D, GL_LUMINANCE, (GLsizei)w0, (GLsizei)h0,
            GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &self->_lumaTexture
        );
        glActiveTexture(GL_TEXTURE1);
        CVReturn r2 = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self->_textureCache, pixelBuffer, NULL,
            GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, (GLsizei)w1, (GLsizei)h1,
            GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1, &self->_chromaTexture
        );

        if (r1 == kCVReturnSuccess && r2 == kCVReturnSuccess && self->_lumaTexture && self->_chromaTexture) {
            glBindTexture(CVOpenGLESTextureGetTarget(self->_lumaTexture), CVOpenGLESTextureGetName(self->_lumaTexture));
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

            glBindTexture(CVOpenGLESTextureGetTarget(self->_chromaTexture), CVOpenGLESTextureGetName(self->_chromaTexture));
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

            self->_hasVideoContent = YES;
            self->_showVideoLayer = YES;
            [self renderCurrentFrameOnMain];
        }
        CVPixelBufferRelease(pixelBuffer);
    });
}

- (void)updateCursor:(IPD2Cursor)cursor {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_cursorX = cursor.normX;
        self->_cursorY = cursor.normY;
        self->_cursorVisible = (cursor.visible != 0);
        if (self->_hasRetinaContent || self->_hasVideoContent) {
            [self renderCurrentFrameOnMain];
        }
    });
}

- (void)renderCurrentFrameOnMain {
    if (!_context) return;
    if (_needsResize || _backingWidth <= 0 || _backingHeight <= 0) {
        [self rebuildRenderbufferOnMain];
    }
    if (_backingWidth <= 0 || _backingHeight <= 0) return;
    if (![EAGLContext setCurrentContext:_context]) return;

    BOOL useVideo = (_showVideoLayer && _hasVideoContent && _lumaTexture && _chromaTexture);
    if (!useVideo && !_hasRetinaContent) return;

    float srcW = useVideo ? (float)_videoW : (float)_retinaW;
    float srcH = useVideo ? (float)_videoH : (float)_retinaH;
    if (srcW <= 0 || srcH <= 0) return;

    float sx = 1.0f, sy = 1.0f;
    if (!self.fillScreen) {
        float srcAspect = srcW / srcH;
        float dstAspect = (float)_backingWidth / (float)_backingHeight;
        if (dstAspect > srcAspect) {
            sx = srcAspect / dstAspect;
            sy = 1.0f;
        } else {
            sx = 1.0f;
            sy = dstAspect / srcAspect;
        }
    }

    CGFloat scale = [UIScreen mainScreen].scale;
    CGFloat viewW = (CGFloat)_backingWidth / scale;
    CGFloat viewH = (CGFloat)_backingHeight / scale;
    CGFloat rw = viewW * sx;
    CGFloat rh = viewH * sy;
    self.activeImageRectInPoints = CGRectMake((viewW - rw) * 0.5, (viewH - rh) * 0.5, rw, rh);

    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glViewport(0, 0, _backingWidth, _backingHeight);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_BLEND);

    glBindBuffer(GL_ARRAY_BUFFER, _quadVBO);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, (const void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, (const void *)8);

    if (useVideo && _yuvProgram) {
        glUseProgram(_yuvProgram);
        glUniform2f(_yuvLocScale, sx, sy);
        glUniform2f(_yuvLocOffset, 0.0f, 0.0f);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(CVOpenGLESTextureGetTarget(_lumaTexture), CVOpenGLESTextureGetName(_lumaTexture));
        glUniform1i(_yuvLocY, 0);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(CVOpenGLESTextureGetTarget(_chromaTexture), CVOpenGLESTextureGetName(_chromaTexture));
        glUniform1i(_yuvLocUV, 1);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    } else if (_bgraProgram) {
        glUseProgram(_bgraProgram);
        glUniform2f(_bgraLocScale, sx, sy);
        glUniform2f(_bgraLocOffset, 0.0f, 0.0f);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, _retinaTex);
        BOOL exact = (!self.fillScreen && _retinaW == _backingWidth && _retinaH == _backingHeight);
        GLint filt = exact ? GL_NEAREST : GL_LINEAR;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filt);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filt);
        glUniform1i(_bgraLocTex, 0);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    if (_cursorVisible && _cursorTex && _cursorProgram) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(_cursorProgram);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, _cursorTex);
        glUniform1i(_curLocTex, 0);

        float cwNdc = 40.0f / (float)_backingWidth;
        float chNdc = 56.0f / (float)_backingHeight;
        float tipNdcX = ((_cursorX * 2.0f - 1.0f) * sx);
        float tipNdcY = ((1.0f - _cursorY * 2.0f) * sy);
        float offX = tipNdcX + cwNdc - (6.0f / (float)_backingWidth);
        float offY = tipNdcY - chNdc + (6.0f / (float)_backingHeight);

        glUniform2f(_curLocScale, cwNdc, chNdc);
        glUniform2f(_curLocOffset, offX, offY);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glDisable(GL_BLEND);
    }

    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER];
}

@end
