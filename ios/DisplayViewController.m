#import "DisplayViewController.h"

@interface HiddenKeyboardField : UIView <UIKeyInput>
@property (nonatomic, copy) void (^onText)(NSString *text);
@property (nonatomic, copy) void (^onSpecial)(uint32_t code);
@end

@implementation HiddenKeyboardField
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (void)insertText:(NSString *)text {
    if ([text isEqualToString:@"\n"]) {
        if (self.onSpecial) self.onSpecial(1);
    } else if ([text isEqualToString:@"\t"]) {
        if (self.onSpecial) self.onSpecial(3);
    } else if (self.onText) {
        self.onText(text);
    }
}
- (void)deleteBackward {
    if (self.onSpecial) self.onSpecial(2);
}
@end

@interface DisplayViewController () {
    BOOL _touchEnabled;
    BOOL _barHidden;
    BOOL _hasFirstFrame;
    BOOL _isDragging;
    BOOL _isScrolling;
    BOOL _longPressFired;
    CGPoint _touchStartPt;
    CGPoint _touchLastPt;
    NSUInteger _activeTouchCount;
    CFTimeInterval _lastTapTime;
    uint32_t _fpsFrames;
    CFTimeInterval _fpsLastTime;
    uint16_t _measuredFPS;
    float _lastRttMs;
}

@property (nonatomic, strong, readwrite) GLDisplayView *glView;
@property (nonatomic, strong, readwrite) VideoDecoder *videoDecoder;
@property (nonatomic, strong) UIView *loaderView;
@property (nonatomic, strong) UILabel *loaderLabel;
@property (nonatomic, strong) UIView *floatingBar;
@property (nonatomic, strong) UIButton *handleBtn;
@property (nonatomic, strong) UIButton *btnSwitch;
@property (nonatomic, strong) UIButton *btnPreset;
@property (nonatomic, strong) UIButton *btnFit;
@property (nonatomic, strong) UIButton *btnTouch;
@property (nonatomic, strong) UILabel *hudLabel;
@property (nonatomic, strong) HiddenKeyboardField *kbField;
@property (nonatomic, strong) NSTimer *autoHideTimer;
@property (nonatomic, strong) NSTimer *longPressTimer;

@end

@implementation DisplayViewController

- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.view.multipleTouchEnabled = YES;

    _touchEnabled = YES;
    _barHidden = NO;
    _fpsLastTime = CACurrentMediaTime();

    self.videoDecoder = [[VideoDecoder alloc] init];
    self.videoDecoder.delegate = self;

    self.glView = [[GLDisplayView alloc] initWithFrame:self.view.bounds];
    self.glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.glView.userInteractionEnabled = NO;
    [self.view addSubview:self.glView];

    [self buildLoaderUI];
    [self buildToolbarUI];
    [self buildHiddenKeyboard];
    [self showToolbarTemporarily];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.glView setNeedsLayout];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_hasFirstFrame && self.connection.isConnected) {
            [self.connection sendControlCmd:IPD2_CTRL_REQUEST_SYNC arg1:0];
        }
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.autoHideTimer invalidate];
    [self.longPressTimer invalidate];
    [self.kbField resignFirstResponder];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    self.handleBtn.frame = CGRectMake((w - 92.0) * 0.5, 0, 92.0, 24.0);
    CGFloat barW = MIN(w - 24.0, 740.0);
    self.floatingBar.frame = CGRectMake((w - barW) * 0.5, 14.0, barW, 44.0);
    self.loaderView.frame = self.view.bounds;
    [self layoutToolbarContents];
}

- (void)buildLoaderUI {
    self.loaderView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.loaderView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
    self.loaderView.userInteractionEnabled = NO;

    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    spin.center = CGPointMake(self.view.bounds.size.width * 0.5, self.view.bounds.size.height * 0.5 - 24.0);
    spin.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [spin startAnimating];
    [self.loaderView addSubview:spin];

    self.loaderLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, self.view.bounds.size.height * 0.5 + 16, self.view.bounds.size.width - 40, 28)];
    self.loaderLabel.text = @"Sincronizando tela Retina 2048×1536...";
    self.loaderLabel.textColor = [UIColor whiteColor];
    self.loaderLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.loaderLabel.textAlignment = NSTextAlignmentCenter;
    self.loaderLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.loaderView addSubview:self.loaderLabel];

    [self.view addSubview:self.loaderView];
}

- (UIButton *)makePillButton:(NSString *)title bg:(UIColor *)bg action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 15.0;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildToolbarUI {
    self.handleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.handleBtn.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.6];
    self.handleBtn.layer.cornerRadius = 10.0;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(27, 10, 38, 4)];
    bar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    bar.layer.cornerRadius = 2.0;
    bar.userInteractionEnabled = NO;
    [self.handleBtn addSubview:bar];
    [self.handleBtn addTarget:self action:@selector(toggleToolbar) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.handleBtn];

    self.floatingBar = [[UIView alloc] initWithFrame:CGRectMake(0, 14, 720, 44)];
    self.floatingBar.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:0.92];
    self.floatingBar.layer.cornerRadius = 22.0;
    self.floatingBar.layer.borderWidth = 1.0;
    self.floatingBar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    [self.view addSubview:self.floatingBar];

    UIColor *subtle = [UIColor colorWithWhite:1.0 alpha:0.14];
    UIColor *blue   = [UIColor colorWithRed:0.0 green:0.44 blue:0.89 alpha:1.0];
    UIColor *green  = [UIColor colorWithRed:0.18 green:0.75 blue:0.35 alpha:0.35];

    UIButton *btnBack = [self makePillButton:@"Menu" bg:blue action:@selector(onBack)];
    btnBack.tag = 101;
    [self.floatingBar addSubview:btnBack];

    self.btnSwitch = [self makePillButton:(self.activeMode == IPD2_MODE_SECOND ? @"Espelhar" : @"2ª Tela") bg:subtle action:@selector(onSwitchMode)];
    [self.floatingBar addSubview:self.btnSwitch];

    self.hudLabel = [[UILabel alloc] init];
    self.hudLabel.text = @"Retina 2048×1536";
    self.hudLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    self.hudLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightSemibold];
    self.hudLabel.textAlignment = NSTextAlignmentCenter;
    [self.floatingBar addSubview:self.hudLabel];

    self.btnPreset = [self makePillButton:@"Retina 1:1" bg:subtle action:@selector(onTogglePreset)];
    [self.floatingBar addSubview:self.btnPreset];

    self.btnFit = [self makePillButton:@"Ajustar" bg:subtle action:@selector(onToggleFit)];
    [self.floatingBar addSubview:self.btnFit];

    self.btnTouch = [self makePillButton:@"Toque" bg:green action:@selector(onToggleTouch)];
    [self.floatingBar addSubview:self.btnTouch];

    UIButton *btnKB = [self makePillButton:@"Teclado" bg:subtle action:@selector(onToggleKeyboard)];
    btnKB.tag = 102;
    [self.floatingBar addSubview:btnKB];

    UIButton *btnHide = [self makePillButton:@"✕" bg:subtle action:@selector(hideToolbar)];
    btnHide.tag = 103;
    [self.floatingBar addSubview:btnHide];
}

- (void)layoutToolbarContents {
    CGFloat w = self.floatingBar.bounds.size.width;
    CGFloat y = 7.0, h = 30.0;
    UIView *btnBack = [self.floatingBar viewWithTag:101];
    UIView *btnKB   = [self.floatingBar viewWithTag:102];
    UIView *btnHide = [self.floatingBar viewWithTag:103];

    btnBack.frame        = CGRectMake(8, y, 64, h);
    self.btnSwitch.frame = CGRectMake(78, y, 82, h);

    btnHide.frame        = CGRectMake(w - 38, y, 30, h);
    btnKB.frame          = CGRectMake(w - 112, y, 68, h);
    self.btnTouch.frame  = CGRectMake(w - 180, y, 62, h);
    self.btnFit.frame    = CGRectMake(w - 252, y, 66, h);
    self.btnPreset.frame = CGRectMake(w - 342, y, 84, h);

    CGFloat hudX = 166;
    CGFloat hudW = MAX(40, (w - 348) - hudX);
    self.hudLabel.frame = CGRectMake(hudX, y, hudW, h);
}

- (void)buildHiddenKeyboard {
    self.kbField = [[HiddenKeyboardField alloc] initWithFrame:CGRectMake(-10, -10, 1, 1)];
    __weak typeof(self) weakSelf = self;
    self.kbField.onText = ^(NSString *text) {
        for (NSUInteger i = 0; i < text.length; i++) {
            IPD2Input inp;
            memset(&inp, 0, sizeof(inp));
            inp.eventType = IPD2_INPUT_KEY_CHAR;
            inp.keyData = (uint32_t)[text characterAtIndex:i];
            [weakSelf.connection sendInput:inp];
        }
    };
    self.kbField.onSpecial = ^(uint32_t code) {
        IPD2Input inp;
        memset(&inp, 0, sizeof(inp));
        inp.eventType = IPD2_INPUT_KEY_SPECIAL;
        inp.keyData = code;
        [weakSelf.connection sendInput:inp];
    };
    [self.view addSubview:self.kbField];
}

#pragma mark - Toolbar Actions

- (void)showToolbarTemporarily {
    _barHidden = NO;
    self.floatingBar.hidden = NO;
    [self.autoHideTimer invalidate];
    self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self selector:@selector(hideToolbar) userInfo:nil repeats:NO];
}

- (void)hideToolbar {
    _barHidden = YES;
    self.floatingBar.hidden = YES;
    [self.autoHideTimer invalidate];
}

- (void)toggleToolbar {
    if (_barHidden) [self showToolbarTemporarily];
    else [self hideToolbar];
}

- (void)onBack {
    [self.kbField resignFirstResponder];
    [self.glView clearDisplay];
    [self.videoDecoder reset];
    [self.delegate displayViewControllerDidRequestBack:self];
}

- (void)onSwitchMode {
    uint8_t next = (self.activeMode == IPD2_MODE_SECOND) ? IPD2_MODE_MIRROR : IPD2_MODE_SECOND;
    self.activeMode = next;
    _hasFirstFrame = NO;
    self.loaderView.hidden = NO;
    self.loaderLabel.text = (next == IPD2_MODE_SECOND) ? @"Ativando Segunda Tela Retina..." : @"Iniciando Espelhamento Retina...";
    [self.btnSwitch setTitle:(next == IPD2_MODE_SECOND ? @"Espelhar" : @"2ª Tela") forState:UIControlStateNormal];
    [self.glView clearDisplay];
    [self.videoDecoder reset];
    [self.delegate displayViewControllerDidSelectMode:next];
    [self showToolbarTemporarily];
}

- (void)onTogglePreset {
    self.activePreset = (self.activePreset + 1) % 3;
    NSArray *names = @[ @"Retina 1:1", @"Mais Espaço", @"Wi-Fi Rápido" ];
    [self.btnPreset setTitle:names[self.activePreset] forState:UIControlStateNormal];
    [self.delegate displayViewControllerDidSelectPreset:self.activePreset];
    [self showToolbarTemporarily];
}

- (void)onToggleFit {
    self.glView.fillScreen = !self.glView.fillScreen;
    [self.btnFit setTitle:(self.glView.fillScreen ? @"Preencher" : @"Ajustar") forState:UIControlStateNormal];
    [self showToolbarTemporarily];
}

- (void)onToggleTouch {
    _touchEnabled = !_touchEnabled;
    self.btnTouch.backgroundColor = _touchEnabled
        ? [UIColor colorWithRed:0.18 green:0.75 blue:0.35 alpha:0.35]
        : [UIColor colorWithWhite:1.0 alpha:0.12];
    [self.btnTouch setTitle:(_touchEnabled ? @"Toque" : @"Sem Toque") forState:UIControlStateNormal];
    [self showToolbarTemporarily];
}

- (void)onToggleKeyboard {
    if ([self.kbField isFirstResponder]) [self.kbField resignFirstResponder];
    else [self.kbField becomeFirstResponder];
    [self showToolbarTemporarily];
}

#pragma mark - Stream Frame Handlers

- (void)markFrameRendered {
    _fpsFrames++;
    CFTimeInterval now = CACurrentMediaTime();
    if (!_hasFirstFrame) {
        _hasFirstFrame = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loaderView.hidden = YES;
        });
    }
    if (now - _fpsLastTime >= 1.0) {
        _measuredFPS = (uint16_t)((double)_fpsFrames / (now - _fpsLastTime) + 0.5);
        _fpsFrames = 0;
        _fpsLastTime = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshHud];
        });
    }
}

- (void)refreshHud {
    uint16_t w = self.glView.retinaWidth;
    uint16_t h = self.glView.retinaHeight;
    NSString *res = (w > 0 && h > 0) ? [NSString stringWithFormat:@"%u×%u", w, h] : [NSString stringWithFormat:@"GL %dx%d", self.glView.backingWidth, self.glView.backingHeight];
    self.hudLabel.text = [NSString stringWithFormat:@"%@ • %u FPS • %.1fms", res, _measuredFPS, _lastRttMs];
}

- (void)handleTileBatch:(NSData *)payload flags:(uint8_t)flags tileCount:(uint16_t)tileCount seq:(uint32_t)seq {
    [self.glView applyTileBatchData:payload flags:flags tileCount:tileCount];
    [self markFrameRendered];
}

- (void)handleH264Config:(NSData *)payload {
    if (payload.length < sizeof(IPD2H264ConfigHeader)) return;
    const uint8_t *bytes = (const uint8_t *)payload.bytes;
    IPD2H264ConfigHeader ch;
    memcpy(&ch, bytes, sizeof(ch));
    if (payload.length < sizeof(ch) + ch.spsLen + ch.ppsLen) return;
    const uint8_t *sps = bytes + sizeof(ch);
    const uint8_t *pps = sps + ch.spsLen;
    [self.videoDecoder configureWithSPS:sps spsLen:ch.spsLen pps:pps ppsLen:ch.ppsLen width:ch.videoW height:ch.videoH];
}

- (void)handleH264Frame:(NSData *)payload isKeyframe:(BOOL)isKey seq:(uint32_t)seq {
    if (payload.length <= sizeof(IPD2H264FrameHeader)) return;
    const uint8_t *bytes = (const uint8_t *)payload.bytes;
    IPD2H264FrameHeader fh;
    memcpy(&fh, bytes, sizeof(fh));
    [self.videoDecoder decodeAVCCData:bytes + sizeof(fh) length:payload.length - sizeof(fh) ptsUs:fh.ptsUs];
    [self.connection sendFrameAck:seq];
}

- (void)videoDecoderDidOutputPixelBuffer:(CVPixelBufferRef)pixelBuffer ptsUs:(uint64_t)ptsUs {
    [self.glView displayH264PixelBuffer:pixelBuffer];
    [self markFrameRendered];
}

- (void)handleCursor:(IPD2Cursor)cursor {
    [self.glView updateCursor:cursor];
}

- (void)handleDisplayInfo:(IPD2DisplayInfo)info {
    _lastRttMs = info.rttTenthMs / 10.0f;
    [self refreshHud];
}

- (void)showDisconnectedBanner {
    self.loaderView.hidden = NO;
    self.loaderLabel.text = @"Conexão perdida — reconectando ao computador...";
}

#pragma mark - Full Native Multi-Touch Gesture Engine

- (CGPoint)normalizedPointForViewPoint:(CGPoint)pt {
    CGRect imgRect = self.glView.activeImageRectInPoints;
    if (imgRect.size.width < 1 || imgRect.size.height < 1) imgRect = self.view.bounds;
    CGFloat nx = (pt.x - imgRect.origin.x) / imgRect.size.width;
    CGFloat ny = (pt.y - imgRect.origin.y) / imgRect.size.height;
    if (nx < 0) nx = 0; if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; if (ny > 1) ny = 1;
    return CGPointMake(nx, ny);
}

- (void)sendMouse:(uint8_t)type pt:(CGPoint)pt clicks:(uint16_t)clicks {
    CGPoint n = [self normalizedPointForViewPoint:pt];
    IPD2Input inp;
    memset(&inp, 0, sizeof(inp));
    inp.eventType = type;
    inp.clickCount = clicks;
    inp.x = (float)n.x;
    inp.y = (float)n.y;
    [self.connection sendInput:inp];
}

- (void)onLongPressFired {
    if (!_isDragging && _activeTouchCount == 1) {
        _longPressFired = YES;
        [self sendMouse:IPD2_INPUT_RIGHT_DOWN pt:_touchStartPt clicks:1];
        [self sendMouse:IPD2_INPUT_RIGHT_UP pt:_touchStartPt clicks:1];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.longPressTimer invalidate];
    NSSet<UITouch *> *all = [event allTouches];
    _activeTouchCount = all.count;
    _isDragging = NO;
    _isScrolling = NO;
    _longPressFired = NO;

    if (_activeTouchCount == 3) {
        [self toggleToolbar];
        return;
    }
    if (!_touchEnabled) return;

    if (_activeTouchCount == 1) {
        CGPoint p = [[all anyObject] locationInView:self.view];
        _touchStartPt = p;
        _touchLastPt = p;
        [self sendMouse:IPD2_INPUT_MOVE pt:p clicks:0];
        self.longPressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(onLongPressFired) userInfo:nil repeats:NO];
    } else if (_activeTouchCount == 2) {
        NSArray<UITouch *> *arr = [all allObjects];
        CGPoint p0 = [arr[0] locationInView:self.view];
        CGPoint p1 = [arr[1] locationInView:self.view];
        _touchStartPt = CGPointMake((p0.x + p1.x) * 0.5, (p0.y + p1.y) * 0.5);
        _touchLastPt = _touchStartPt;
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_touchEnabled) return;
    NSSet<UITouch *> *all = [event allTouches];

    if (all.count == 1 && _activeTouchCount == 1 && !_longPressFired) {
        CGPoint p = [[all anyObject] locationInView:self.view];
        CGFloat dx = p.x - _touchStartPt.x;
        CGFloat dy = p.y - _touchStartPt.y;
        if (!_isDragging && (dx * dx + dy * dy) > 64.0) {
            _isDragging = YES;
            [self.longPressTimer invalidate];
            [self sendMouse:IPD2_INPUT_LEFT_DOWN pt:_touchStartPt clicks:1];
        }
        if (_isDragging) {
            [self sendMouse:IPD2_INPUT_LEFT_DRAG pt:p clicks:1];
        }
        _touchLastPt = p;
    } else if (all.count == 2) {
        NSArray<UITouch *> *arr = [all allObjects];
        CGPoint p0 = [arr[0] locationInView:self.view];
        CGPoint p1 = [arr[1] locationInView:self.view];
        CGPoint mid = CGPointMake((p0.x + p1.x) * 0.5, (p0.y + p1.y) * 0.5);
        float sdx = (float)((mid.x - _touchLastPt.x) * 2.2);
        float sdy = (float)((mid.y - _touchLastPt.y) * 2.2);
        if (fabsf(sdx) > 1.0f || fabsf(sdy) > 1.0f) {
            _isScrolling = YES;
            IPD2Input inp;
            memset(&inp, 0, sizeof(inp));
            inp.eventType = IPD2_INPUT_SCROLL;
            inp.x = sdx;
            inp.y = sdy;
            [self.connection sendInput:inp];
        }
        _touchLastPt = mid;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.longPressTimer invalidate];
    if (!_touchEnabled) return;

    if (_activeTouchCount == 1 && !_longPressFired) {
        if (_isDragging) {
            [self sendMouse:IPD2_INPUT_LEFT_UP pt:_touchLastPt clicks:1];
        } else {
            CFTimeInterval now = CACurrentMediaTime();
            if (now - _lastTapTime < 0.32) {
                [self sendMouse:IPD2_INPUT_DOUBLE_CLICK pt:_touchLastPt clicks:2];
                _lastTapTime = 0;
            } else {
                [self sendMouse:IPD2_INPUT_LEFT_DOWN pt:_touchLastPt clicks:1];
                [self sendMouse:IPD2_INPUT_LEFT_UP pt:_touchLastPt clicks:1];
                _lastTapTime = now;
            }
        }
    } else if (_activeTouchCount == 2 && !_isScrolling) {
        [self sendMouse:IPD2_INPUT_RIGHT_DOWN pt:_touchStartPt clicks:1];
        [self sendMouse:IPD2_INPUT_RIGHT_UP pt:_touchStartPt clicks:1];
    }

    _activeTouchCount = 0;
    _isDragging = NO;
    _isScrolling = NO;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.longPressTimer invalidate];
    if (_isDragging) {
        [self sendMouse:IPD2_INPUT_LEFT_UP pt:_touchLastPt clicks:1];
    }
    _activeTouchCount = 0;
    _isDragging = NO;
    _isScrolling = NO;
}

@end
