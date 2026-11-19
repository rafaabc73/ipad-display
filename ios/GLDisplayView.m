#import "GLDisplayView.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import "../shared/lz4/lz4.h"
#include <stdlib.h>
#include <string.h>

@interface GLDisplayView () {
    EAGLContext *_context;
    GLuint _framebuffer;
    GLuint _colorRenderbuffer;
    GLint _backingWidth;
    GLint _backingHeight;

    GLuint _bgraProgram;
    GLuint _yuvProgram;
    GLuint _cursorProgram;
    GLuint _quadVBO;

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

    uint8_t *_lz4DecodeBuf;
    size_t _lz4DecodeBufSize;

    dispatch_queue_t _glQueue;
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
    glDeleteShader(vs);
    glDeleteShader(fs);
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
        self.contentScaleFactor = [UIScreen mainScreen].scale; // 2.0 on iPad 4 -> exact 2048x1536!

        CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
        eaglLayer.opaque = YES;
        eaglLayer.contentsScale = self.contentScaleFactor;
        eaglLayer.drawableProperties = @{
            kEAGLDrawablePropertyRetainedBacking: @NO,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        };

        _glQueue = dispatch_queue_create("ipd2.ios.gl", DISPATCH_QUEUE_SERIAL);
        _lz4DecodeBufSize = 256 * 256 * 4;
        _lz4DecodeBuf = (uint8_t *)malloc(_lz4DecodeBufSize);
        _activeImageRectInPoints = frame;
        _needsResize = YES;

        [self setupGL];
    }
    return self;
}

- (void)dealloc {
    [self teardownGL];
    if (_lz4DecodeBuf) { free(_lz4DecodeBuf); _lz4DecodeBuf = NULL; }
}

- (uint16_t)retinaWidth { return _retinaW; }
- (uint16_t)retinaHeight { return _retinaH; }

- (void)setFillScreen:(BOOL)fillScreen {
    _fillScreen = fillScreen;
    dispatch_async(_glQueue, ^{
        [self renderCurrentFrameLocked];
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
    eaglLayer.contentsScale = [UIScreen mainScreen].scale;
    dispatch_async(_glQueue, ^{
        self->_needsResize = YES;
        [self rebuildRenderbufferLocked];
        [self renderCurrentFrameLocked];
    });
}

- (void)setupGL {
    dispatch_sync(_glQueue, ^{
        self->_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        if (!self->_context || ![EAGLContext setCurrentContext:self->_context]) return;

        glGenFramebuffers(1, &self->_framebuffer);
        glGenRenderbuffers(1, &self->_colorRenderbuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, self->_framebuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, self->_colorRenderbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self->_colorRenderbuffer);

        // Fullscreen quad VBO (pos.xy, tex.uv)
        static const GLfloat quadVerts[] = {
            -1.0f, -1.0f,  0.0f, 1.0f,
             1.0f, -1.0f,  1.0f, 1.0f,
            -1.0f,  1.0f,  0.0f, 0.0f,
             1.0f,  1.0f,  1.0f, 0.0f
        };
        glGenBuffers(1, &self->_quadVBO);
        glBindBuffer(GL_ARRAY_BUFFER, self->_quadVBO);
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

        // BGRA Retina texture shader (GL_BGRA_EXT already delivers RGBA in correct channels!)
        const char *fsBGRA =
            "precision mediump float;"
            "varying vec2 vTex;"
            "uniform sampler2D uTex;"
            "void main() {"
            "  gl_FragColor = vec4(texture2D(uTex, vTex).rgb, 1.0);"
            "}";

        // Zero-copy BT.709 Video-Range NV12 YUV->RGB shader (hardware H.264 @ 60 FPS!)
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

        // Alpha-blended Retina cursor sprite shader
        const char *fsCursor =
            "precision mediump float;"
            "varying vec2 vTex;"
            "uniform sampler2D uTex;"
            "void main() {"
            "  gl_FragColor = texture2D(uTex, vTex);"
            "}";

        self->_bgraProgram = link_program(vs, fsBGRA);
        self->_yuvProgram = link_program(vs, fsYUV);
        self->_cursorProgram = link_program(vs, fsCursor);

        glGenTextures(1, &self->_retinaTex);
        glBindTexture(GL_TEXTURE_2D, self->_retinaTex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        [self buildRetinaCursorTextureLocked];
        CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self->_context, NULL, &self->_textureCache);
    });
}

- (void)buildRetinaCursorTextureLocked {
    const int cw = 40, ch = 56;
    uint8_t *buf = (uint8_t *)calloc(1, cw * ch * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, cw, ch, 8, cw * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (ctx) {
        // Flip CoreGraphics coordinates so tip is at (2, 2) top-left
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

- (void)rebuildRenderbufferLocked {
    if (!_context) return;
    [EAGLContext setCurrentContext:_context];
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);

    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        ok = [self->_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    });
    if (ok) {
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
        _needsResize = NO;
    }
}

- (void)releaseVideoTexturesLocked {
    if (_lumaTexture) { CFRelease(_lumaTexture); _lumaTexture = NULL; }
    if (_chromaTexture) { CFRelease(_chromaTexture); _chromaTexture = NULL; }
    if (_textureCache) { CVOpenGLESTextureCacheFlush(_textureCache, 0); }
}

- (void)teardownGL {
    if (!_glQueue) return;
    dispatch_sync(_glQueue, ^{
        if (self->_context) {
            [EAGLContext setCurrentContext:self->_context];
            [self releaseVideoTexturesLocked];
            if (self->_textureCache) { CFRelease(self->_textureCache); self->_textureCache = NULL; }
            if (self->_retinaTex) { glDeleteTextures(1, &self->_retinaTex); self->_retinaTex = 0; }
            if (self->_cursorTex) { glDeleteTextures(1, &self->_cursorTex); self->_cursorTex = 0; }
            if (self->_quadVBO) { glDeleteBuffers(1, &self->_quadVBO); self->_quadVBO = 0; }
            if (self->_bgraProgram) { glDeleteProgram(self->_bgraProgram); self->_bgraProgram = 0; }
            if (self->_yuvProgram) { glDeleteProgram(self->_yuvProgram); self->_yuvProgram = 0; }
            if (self->_cursorProgram) { glDeleteProgram(self->_cursorProgram); self->_cursorProgram = 0; }
            if (self->_colorRenderbuffer) { glDeleteRenderbuffers(1, &self->_colorRenderbuffer); self->_colorRenderbuffer = 0; }
            if (self->_framebuffer) { glDeleteFramebuffers(1, &self->_framebuffer); self->_framebuffer = 0; }
            [EAGLContext setCurrentContext:nil];
            self->_context = nil;
        }
    });
}

- (void)clearDisplay {
    dispatch_async(_glQueue, ^{
        self->_hasRetinaContent = NO;
        self->_hasVideoContent = NO;
        self->_showVideoLayer = NO;
        self->_cursorVisible = NO;
        self->_retinaW = 0;
        self->_retinaH = 0;
        [self releaseVideoTexturesLocked];
        if (!self->_context) return;
        [EAGLContext setCurrentContext:self->_context];
        if (self->_needsResize) [self rebuildRenderbufferLocked];
        glBindFramebuffer(GL_FRAMEBUFFER, self->_framebuffer);
        glViewport(0, 0, self->_backingWidth, self->_backingHeight);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glBindRenderbuffer(GL_RENDERBUFFER, self->_colorRenderbuffer);
        [self->_context presentRenderbuffer:GL_RENDERBUFFER];
    });
}

- (void)applyTileBatchData:(NSData *)payload flags:(uint8_t)flags tileCount:(uint16_t)tileCount {
    if (!payload || payload.length < sizeof(IPD2TileBatchHeader)) return;
    if (flags & IPD2_TILE_FLAG_HALF_RES) return; // Native App uses HW H.264 for motion!

    dispatch_async(_glQueue, ^{
        if (!self->_context) return;
        [EAGLContext setCurrentContext:self->_context];
        if (self->_needsResize || self->_backingWidth <= 0) [self rebuildRenderbufferLocked];

        const uint8_t *bytes = (const uint8_t *)payload.bytes;
        size_t totalLen = payload.length;
        IPD2TileBatchHeader bh;
        memcpy(&bh, bytes, sizeof(bh));

        glBindTexture(GL_TEXTURE_2D, self->_retinaTex);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4);

        if (bh.frameW > 0 && bh.frameH > 0 && (bh.frameW != self->_retinaW || bh.frameH != self->_retinaH)) {
            self->_retinaW = bh.frameW;
            self->_retinaH = bh.frameH;
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, self->_retinaW, self->_retinaH,
                         0, GL_BGRA_EXT, GL_UNSIGNED_BYTE, NULL);
        }

        size_t off = sizeof(IPD2TileBatchHeader);
        for (uint16_t i = 0; i < tileCount; i++) {
            if (off + sizeof(IPD2TileHeader) > totalLen) break;
            IPD2TileHeader th;
            memcpy(&th, bytes + off, sizeof(th));
            off += sizeof(IPD2TileHeader);
            if (off + th.dataLen > totalLen) break;

            size_t rawSize = (size_t)th.w * (size_t)th.h * 4;
            if (rawSize > self->_lz4DecodeBufSize) {
                self->_lz4DecodeBuf = (uint8_t *)realloc(self->_lz4DecodeBuf, rawSize);
                self->_lz4DecodeBufSize = rawSize;
            }

            if (th.encoding == IPD2_ENC_LZ4_BGRA) {
                int dec = LZ4_decompress_safe((const char *)(bytes + off),
                                              (char *)self->_lz4DecodeBuf,
                                              (int)th.dataLen,
                                              (int)rawSize);
                if (dec == (int)rawSize) {
                    glTexSubImage2D(GL_TEXTURE_2D, 0, th.x, th.y, th.w, th.h,
                                    GL_BGRA_EXT, GL_UNSIGNED_BYTE, self->_lz4DecodeBuf);
                }
            } else if (th.encoding == IPD2_ENC_RAW_BGRA && th.dataLen == rawSize) {
                glTexSubImage2D(GL_TEXTURE_2D, 0, th.x, th.y, th.w, th.h,
                                GL_BGRA_EXT, GL_UNSIGNED_BYTE, bytes + off);
            }
            off += th.dataLen;
        }

        self->_hasRetinaContent = YES;
        if ((flags & IPD2_TILE_FLAG_FULL_SYNC) || !self->_showVideoLayer) {
            self->_showVideoLayer = NO;
        }
        [self renderCurrentFrameLocked];
    });
}

- (void)displayH264PixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(_glQueue, ^{
        if (!self->_context || !self->_textureCache) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        [EAGLContext setCurrentContext:self->_context];
        if (self->_needsResize || self->_backingWidth <= 0) [self rebuildRenderbufferLocked];

        [self releaseVideoTexturesLocked];

        size_t w = CVPixelBufferGetWidth(pixelBuffer);
        size_t h = CVPixelBufferGetHeight(pixelBuffer);
        self->_videoW = (uint16_t)w;
        self->_videoH = (uint16_t)h;

        glActiveTexture(GL_TEXTURE0);
        CVReturn r1 = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self->_textureCache, pixelBuffer, NULL,
            GL_TEXTURE_2D, GL_LUMINANCE, (GLsizei)w, (GLsizei)h,
            GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &self->_lumaTexture
        );
        glActiveTexture(GL_TEXTURE1);
        CVReturn r2 = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, self->_textureCache, pixelBuffer, NULL,
            GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, (GLsizei)(w / 2), (GLsizei)(h / 2),
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
            [self renderCurrentFrameLocked];
        }
        CVPixelBufferRelease(pixelBuffer);
    });
}

- (void)updateCursor:(IPD2Cursor)cursor {
    dispatch_async(_glQueue, ^{
        self->_cursorX = cursor.normX;
        self->_cursorY = cursor.normY;
        self->_cursorVisible = (cursor.visible != 0);
        if (self->_hasRetinaContent || self->_hasVideoContent) {
            [self renderCurrentFrameLocked];
        }
    });
}

- (void)renderCurrentFrameLocked {
    if (!_context || _backingWidth <= 0 || _backingHeight <= 0) return;
    [EAGLContext setCurrentContext:_context];

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

    // Store active image rect in UIKit points for accurate multi-touch coordinate mapping
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

    if (useVideo) {
        glUseProgram(_yuvProgram);
        glUniform2f(glGetUniformLocation(_yuvProgram, "uScale"), sx, sy);
        glUniform2f(glGetUniformLocation(_yuvProgram, "uOffset"), 0.0f, 0.0f);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(CVOpenGLESTextureGetTarget(_lumaTexture), CVOpenGLESTextureGetName(_lumaTexture));
        glUniform1i(glGetUniformLocation(_yuvProgram, "uY"), 0);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(CVOpenGLESTextureGetTarget(_chromaTexture), CVOpenGLESTextureGetName(_chromaTexture));
        glUniform1i(glGetUniformLocation(_yuvProgram, "uUV"), 1);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    } else {
        glUseProgram(_bgraProgram);
        glUniform2f(glGetUniformLocation(_bgraProgram, "uScale"), sx, sy);
        glUniform2f(glGetUniformLocation(_bgraProgram, "uOffset"), 0.0f, 0.0f);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, _retinaTex);
        // Exact 1:1 Retina pixel match uses GL_NEAREST for razor-sharp native iPad clarity!
        BOOL exact = (!self.fillScreen && _retinaW == _backingWidth && _retinaH == _backingHeight);
        GLint filt = exact ? GL_NEAREST : GL_LINEAR;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filt);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filt);
        glUniform1i(glGetUniformLocation(_bgraProgram, "uTex"), 0);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    // Hardware-composited 60 Hz Retina cursor sprite overlay!
    if (_cursorVisible && _cursorTex) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(_cursorProgram);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, _cursorTex);
        glUniform1i(glGetUniformLocation(_cursorProgram, "uTex"), 0);

        // Cursor size in NDC (40x56 Retina px)
        float cwNdc = 40.0f / (float)_backingWidth;
        float chNdc = 56.0f / (float)_backingHeight;
        float tipNdcX = ((_cursorX * 2.0f - 1.0f) * sx);
        float tipNdcY = ((1.0f - _cursorY * 2.0f) * sy);
        float offX = tipNdcX + cwNdc - (6.0f / (float)_backingWidth);
        float offY = tipNdcY - chNdc + (6.0f / (float)_backingHeight);

        glUniform2f(glGetUniformLocation(_cursorProgram, "uScale"), cwNdc, chNdc);
        glUniform2f(glGetUniformLocation(_cursorProgram, "uOffset"), offX, offY);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glDisable(GL_BLEND);
    }

    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER];
}

@end
