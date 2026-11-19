#import "HomeViewController.h"
#import "DisplayViewController.h"
#import "../shared/protocol.h"

@interface HomeViewController () <DisplayViewControllerDelegate>
@property (nonatomic, strong, readwrite) ConnectionManager *connection;
@property (nonatomic, strong) DisplayViewController *displayVC;

@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *brandLabel;
@property (nonatomic, strong) UILabel *hostLabel;
@property (nonatomic, strong) UIView *statusPill;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *manualIPBtn;

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *cardSecond;
@property (nonatomic, strong) UIButton *cardMirror;
@property (nonatomic, strong) UISegmentedControl *presetSeg;
@property (nonatomic, strong) UISegmentedControl *posSeg;
@property (nonatomic, strong) UILabel *presetLabel;
@property (nonatomic, strong) UILabel *posLabel;
@property (nonatomic, strong) UILabel *footerLabel;

@property (nonatomic) uint8_t selectedPreset;
@property (nonatomic) uint8_t selectedPosition;
@end

@implementation HomeViewController

- (BOOL)prefersStatusBarHidden { return NO; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.96 green:0.965 blue:0.98 alpha:1.0];
    self.selectedPreset = IPD2_PRESET_RETINA;
    self.selectedPosition = IPD2_POS_RIGHT;

    [self buildUI];

    self.connection = [[ConnectionManager alloc] init];
    self.connection.delegate = self;
    [self.connection start];
}

- (UIButton *)buildModeCardWithTitle:(NSString *)title
                               badge:(NSString *)badge
                                desc:(NSString *)desc
                              ctaStr:(NSString *)ctaStr
                               color:(UIColor *)accent
                              action:(SEL)action {
    UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 22.0;
    card.layer.borderWidth = 2.0;
    card.layer.borderColor = [UIColor colorWithRed:0.89 green:0.90 blue:0.93 alpha:1.0].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.06;
    card.layer.shadowRadius = 14.0;
    card.layer.shadowOffset = CGSizeMake(0, 6);
    [card addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UILabel *badgeLbl = [[UILabel alloc] init];
    badgeLbl.tag = 1;
    badgeLbl.text = [badge uppercaseString];
    badgeLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    badgeLbl.textColor = accent;
    badgeLbl.backgroundColor = [accent colorWithAlphaComponent:0.12];
    badgeLbl.textAlignment = NSTextAlignmentCenter;
    badgeLbl.layer.cornerRadius = 9.0;
    badgeLbl.clipsToBounds = YES;
    badgeLbl.userInteractionEnabled = NO;
    [card addSubview:badgeLbl];

    UILabel *tLbl = [[UILabel alloc] init];
    tLbl.tag = 2;
    tLbl.text = title;
    tLbl.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    tLbl.textColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
    tLbl.userInteractionEnabled = NO;
    [card addSubview:tLbl];

    UILabel *dLbl = [[UILabel alloc] init];
    dLbl.tag = 3;
    dLbl.text = desc;
    dLbl.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightRegular];
    dLbl.textColor = [UIColor colorWithRed:0.43 green:0.43 blue:0.46 alpha:1.0];
    dLbl.numberOfLines = 0;
    dLbl.userInteractionEnabled = NO;
    [card addSubview:dLbl];

    UILabel *cta = [[UILabel alloc] init];
    cta.tag = 4;
    cta.text = ctaStr;
    cta.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    cta.textColor = [UIColor whiteColor];
    cta.backgroundColor = accent;
    cta.textAlignment = NSTextAlignmentCenter;
    cta.layer.cornerRadius = 14.0;
    cta.clipsToBounds = YES;
    cta.userInteractionEnabled = NO;
    [card addSubview:cta];

    return card;
}

- (void)layoutModeCard:(UIButton *)card {
    CGFloat w = card.bounds.size.width;
    CGFloat h = card.bounds.size.height;
    CGFloat pad = 24.0;
    [card viewWithTag:1].frame = CGRectMake(pad, pad, 150, 24);
    [card viewWithTag:2].frame = CGRectMake(pad, pad + 38, w - pad * 2, 32);
    [card viewWithTag:3].frame = CGRectMake(pad, pad + 76, w - pad * 2, h - pad * 2 - 134);
    [card viewWithTag:4].frame = CGRectMake(pad, h - pad - 46, w - pad * 2, 46);
}

- (void)buildUI {
    self.headerView = [[UIView alloc] init];
    self.headerView.backgroundColor = [UIColor whiteColor];
    self.headerView.layer.borderColor = [UIColor colorWithRed:0.90 green:0.90 blue:0.92 alpha:1.0].CGColor;
    self.headerView.layer.borderWidth = 0.5;
    [self.view addSubview:self.headerView];

    self.brandLabel = [[UILabel alloc] init];
    self.brandLabel.text = @"iPad Display Pro";
    self.brandLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    self.brandLabel.textColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
    [self.headerView addSubview:self.brandLabel];

    self.hostLabel = [[UILabel alloc] init];
    self.hostLabel.text = @"Conecte o cabo USB no computador e abra o iPad Display";
    self.hostLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    self.hostLabel.textColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.48 alpha:1.0];
    [self.headerView addSubview:self.hostLabel];

    self.statusPill = [[UIView alloc] init];
    self.statusPill.backgroundColor = [UIColor colorWithRed:1.0 green:0.96 blue:0.88 alpha:1.0];
    self.statusPill.layer.cornerRadius = 17.0;
    self.statusPill.layer.borderWidth = 1.0;
    self.statusPill.layer.borderColor = [UIColor colorWithRed:0.96 green:0.84 blue:0.55 alpha:1.0].CGColor;
    [self.headerView addSubview:self.statusPill];

    self.statusDot = [[UIView alloc] initWithFrame:CGRectMake(12, 12, 10, 10)];
    self.statusDot.layer.cornerRadius = 5.0;
    self.statusDot.backgroundColor = [UIColor orangeColor];
    [self.statusPill addSubview:self.statusDot];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"Aguardando Cabo USB / Wi-Fi...";
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = [UIColor colorWithRed:0.60 green:0.40 blue:0.0 alpha:1.0];
    [self.statusPill addSubview:self.statusLabel];

    self.manualIPBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.manualIPBtn setTitle:@"IP Manual" forState:UIControlStateNormal];
    self.manualIPBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.manualIPBtn addTarget:self action:@selector(onTapManualIP) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.manualIPBtn];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"Escolha como usar seu iPad";
    self.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.text = @"Retina 2048×1536 Lossless + Hardware H.264 60 FPS + Cursor 60 Hz";
    self.subtitleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightRegular];
    self.subtitleLabel.textColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.48 alpha:1.0];
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.subtitleLabel];

    UIColor *green = [UIColor colorWithRed:0.18 green:0.72 blue:0.34 alpha:1.0];
    UIColor *blue  = [UIColor colorWithRed:0.0  green:0.44 blue:0.89 alpha:1.0];

    self.cardSecond = [self buildModeCardWithTitle:@"Segunda Tela"
                                             badge:@"Monitor Estendido"
                                              desc:@"Cria um monitor virtual Retina HiDPI 2× (2048×1536 1:1) independente. Arraste janelas, código e navegadores livremente para o iPad com nitidez idêntica à tela nativa."
                                            ctaStr:@"Ativar Segunda Tela"
                                             color:green
                                            action:@selector(onTapSecond)];
    [self.view addSubview:self.cardSecond];

    self.cardMirror = [self buildModeCardWithTitle:@"Espelhar Tela"
                                             badge:@"Duplicar Monitor"
                                              desc:@"Espelha a tela principal do computador em tempo real preservando a proporção exata sem distorção. Ideal para acompanhar apresentações e controlar o PC por toque."
                                            ctaStr:@"Iniciar Espelhamento"
                                             color:blue
                                            action:@selector(onTapMirror)];
    [self.view addSubview:self.cardMirror];

    self.presetLabel = [[UILabel alloc] init];
    self.presetLabel.text = @"Qualidade:";
    self.presetLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.presetLabel.textColor = [UIColor colorWithRed:0.42 green:0.42 blue:0.45 alpha:1.0];
    [self.view addSubview:self.presetLabel];

    self.presetSeg = [[UISegmentedControl alloc] initWithItems:@[ @"Retina 1:1", @"Mais Espaço", @"Wi-Fi Rápido" ]];
    self.presetSeg.selectedSegmentIndex = 0;
    self.presetSeg.tintColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
    [self.presetSeg addTarget:self action:@selector(onPresetChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.presetSeg];

    self.posLabel = [[UILabel alloc] init];
    self.posLabel.text = @"Posição da 2ª Tela:";
    self.posLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.posLabel.textColor = [UIColor colorWithRed:0.42 green:0.42 blue:0.45 alpha:1.0];
    [self.view addSubview:self.posLabel];

    self.posSeg = [[UISegmentedControl alloc] initWithItems:@[ @"Direita", @"Esquerda", @"Acima", @"Abaixo" ]];
    self.posSeg.selectedSegmentIndex = 0;
    self.posSeg.tintColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
    [self.posSeg addTarget:self action:@selector(onPosChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.posSeg];

    self.footerLabel = [[UILabel alloc] init];
    self.footerLabel.text = @"Gestos na tela: 1 dedo = clique/arraste • 2 dedos = rolar/clique direito • 3 dedos = barra de controle";
    self.footerLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    self.footerLabel.textColor = [UIColor colorWithRed:0.50 green:0.50 blue:0.53 alpha:1.0];
    self.footerLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.footerLabel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    BOOL landscape = (w > h);

    self.headerView.frame = CGRectMake(0, 0, w, 86);
    self.brandLabel.frame = CGRectMake(28, 28, 260, 26);
    self.hostLabel.frame  = CGRectMake(28, 54, w - 390, 18);
    self.manualIPBtn.frame = CGRectMake(w - 104, 34, 80, 34);
    self.statusPill.frame  = CGRectMake(w - 360, 34, 248, 34);
    self.statusLabel.frame = CGRectMake(30, 0, 210, 34);

    CGFloat contentTop = landscape ? 114 : 124;
    self.titleLabel.frame = CGRectMake(24, contentTop, w - 48, 36);
    self.subtitleLabel.frame = CGRectMake(24, contentTop + 40, w - 48, 24);

    CGFloat margin = 32.0;
    CGFloat cardsTop = contentTop + 88;
    if (landscape) {
        CGFloat gap = 24.0;
        CGFloat cardW = MIN(450.0, (w - margin * 2 - gap) * 0.5);
        CGFloat totalW = cardW * 2 + gap;
        CGFloat startX = (w - totalW) * 0.5;
        CGFloat cardH = MIN(340.0, h - cardsTop - 150.0);
        self.cardSecond.frame = CGRectMake(startX, cardsTop, cardW, cardH);
        self.cardMirror.frame = CGRectMake(startX + cardW + gap, cardsTop, cardW, cardH);
    } else {
        CGFloat cardW = w - margin * 2;
        CGFloat cardH = MIN(260.0, (h - cardsTop - 190.0) * 0.5);
        self.cardSecond.frame = CGRectMake(margin, cardsTop, cardW, cardH);
        self.cardMirror.frame = CGRectMake(margin, cardsTop + cardH + 18, cardW, cardH);
    }
    [self layoutModeCard:self.cardSecond];
    [self layoutModeCard:self.cardMirror];

    CGFloat optY = CGRectGetMaxY(self.cardMirror.frame) + 26;
    if (landscape) {
        CGFloat center = w * 0.5;
        self.presetLabel.frame = CGRectMake(center - 440, optY + 4, 80, 24);
        self.presetSeg.frame   = CGRectMake(center - 360, optY, 310, 32);
        self.posLabel.frame    = CGRectMake(center + 10, optY + 4, 128, 24);
        self.posSeg.frame      = CGRectMake(center + 140, optY, 300, 32);
    } else {
        self.presetLabel.frame = CGRectMake(margin, optY, 120, 20);
        self.presetSeg.frame   = CGRectMake(margin, optY + 24, w - margin * 2, 32);
        self.posLabel.frame    = CGRectMake(margin, optY + 66, 160, 20);
        self.posSeg.frame      = CGRectMake(margin, optY + 90, w - margin * 2, 32);
    }

    self.footerLabel.frame = CGRectMake(20, h - 36, w - 40, 22);
}

#pragma mark - User Actions

- (void)onPresetChanged:(UISegmentedControl *)seg {
    self.selectedPreset = (uint8_t)seg.selectedSegmentIndex;
}

- (void)onPosChanged:(UISegmentedControl *)seg {
    self.selectedPosition = (uint8_t)seg.selectedSegmentIndex;
}

- (void)launchDisplayMode:(uint8_t)mode {
    if (!self.connection.isConnected) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Computador não conectado"
                                                                    message:@"Conecte o cabo USB no Mac ou Windows e abra o aplicativo iPad Display no computador, ou toque em 'IP Manual' para conectar por Wi-Fi."
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    self.displayVC = [[DisplayViewController alloc] init];
    self.displayVC.delegate = self;
    self.displayVC.connection = self.connection;
    self.displayVC.activeMode = mode;
    self.displayVC.activePreset = self.selectedPreset;
    self.displayVC.modalPresentationStyle = UIModalPresentationFullScreen;

    [self presentViewController:self.displayVC animated:NO completion:^{
        [self.connection sendControlCmd:IPD2_CTRL_SET_POSITION arg1:self.selectedPosition];
        [self.connection sendControlCmd:IPD2_CTRL_SET_PRESET arg1:self.selectedPreset];
        [self.connection sendControlCmd:IPD2_CTRL_SET_MODE arg1:mode];
    }];
}

- (void)onTapSecond { [self launchDisplayMode:IPD2_MODE_SECOND]; }
- (void)onTapMirror { [self launchDisplayMode:IPD2_MODE_MIRROR]; }

- (void)onTapManualIP {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Conectar por IP"
                                                                message:@"Digite o endereço IP exibido no iPad Display do seu Mac ou Windows:"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Ex: 192.168.100.100";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastManualIP"];
        if (saved.length > 0) tf.text = saved;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Conectar" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *ip = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (ip.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:ip forKey:@"lastManualIP"];
            [self.connection connectToManualHost:ip port:IPD2_TCP_PORT];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - DisplayViewControllerDelegate

- (void)displayViewControllerDidRequestBack:(UIViewController *)vc {
    [self.connection sendControlCmd:IPD2_CTRL_SET_MODE arg1:IPD2_MODE_IDLE];
    [self dismissViewControllerAnimated:NO completion:^{
        self.displayVC = nil;
    }];
}

- (void)displayViewControllerDidSelectMode:(uint8_t)mode {
    [self.connection sendControlCmd:IPD2_CTRL_SET_MODE arg1:mode];
}

- (void)displayViewControllerDidSelectPreset:(uint8_t)preset {
    self.selectedPreset = preset;
    self.presetSeg.selectedSegmentIndex = preset;
    [self.connection sendControlCmd:IPD2_CTRL_SET_PRESET arg1:preset];
}

#pragma mark - ConnectionManagerDelegate

- (void)connectionDidConnectViaTransport:(uint8_t)transport peerLabel:(NSString *)label {
    self.statusPill.backgroundColor = [UIColor colorWithRed:0.92 green:0.98 blue:0.94 alpha:1.0];
    self.statusPill.layer.borderColor = [UIColor colorWithRed:0.78 green:0.92 blue:0.82 alpha:1.0].CGColor;
    self.statusDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
    self.statusLabel.textColor = [UIColor colorWithRed:0.11 green:0.48 blue:0.21 alpha:1.0];
    self.statusLabel.text = (transport == IPD2_TRANSPORT_USB) ? @"Cabo USB Conectado ⚡" : [NSString stringWithFormat:@"Wi-Fi (%@)", label];

    if (self.displayVC) {
        [self.connection sendControlCmd:IPD2_CTRL_SET_POSITION arg1:self.selectedPosition];
        [self.connection sendControlCmd:IPD2_CTRL_SET_PRESET arg1:self.selectedPreset];
        [self.connection sendControlCmd:IPD2_CTRL_SET_MODE arg1:self.displayVC.activeMode];
        [self.connection sendControlCmd:IPD2_CTRL_REQUEST_SYNC arg1:0];
    }
}

- (void)connectionDidDisconnect {
    self.statusPill.backgroundColor = [UIColor colorWithRed:1.0 green:0.96 blue:0.88 alpha:1.0];
    self.statusPill.layer.borderColor = [UIColor colorWithRed:0.96 green:0.84 blue:0.55 alpha:1.0].CGColor;
    self.statusDot.backgroundColor = [UIColor orangeColor];
    self.statusLabel.textColor = [UIColor colorWithRed:0.60 green:0.40 blue:0.0 alpha:1.0];
    self.statusLabel.text = @"Aguardando Cabo USB / Wi-Fi...";
    self.hostLabel.text = @"Conecte o cabo USB no computador e abra o iPad Display";
    if (self.displayVC) {
        [self.displayVC showDisconnectedBanner];
    }
}

- (void)connectionDidReceiveDisplayInfo:(IPD2DisplayInfo)info {
    NSString *name = [NSString stringWithUTF8String:info.hostName] ?: @"Computador";
    NSString *osStr = (info.osKind == IPD2_OS_WINDOWS) ? @"Windows" : @"macOS";
    float rtt = info.rttTenthMs / 10.0f;
    self.hostLabel.text = [NSString stringWithFormat:@"Conectado a %@ (%@)", name, osStr];
    self.statusLabel.text = [NSString stringWithFormat:@"%@ • %.1f ms",
                             (info.transport == IPD2_TRANSPORT_USB) ? @"Cabo USB" : @"Wi-Fi", rtt];
    if (self.displayVC) {
        [self.displayVC handleDisplayInfo:info];
    }
}

- (void)connectionDidReceiveTileBatch:(NSData *)payload flags:(uint8_t)flags tileCount:(uint16_t)tileCount seq:(uint32_t)seq {
    [self.displayVC handleTileBatch:payload flags:flags tileCount:tileCount seq:seq];
}

- (void)connectionDidReceiveH264Config:(NSData *)payload {
    [self.displayVC handleH264Config:payload];
}

- (void)connectionDidReceiveH264Frame:(NSData *)payload isKeyframe:(BOOL)isKey seq:(uint32_t)seq {
    [self.displayVC handleH264Frame:payload isKeyframe:isKey seq:seq];
}

- (void)connectionDidReceiveCursor:(IPD2Cursor)cursor {
    [self.displayVC handleCursor:cursor];
}

- (void)connectionDidUpdateDiscoveredHosts:(NSArray<NSDictionary *> *)hosts {
    if (!self.connection.isConnected && hosts.count > 0) {
        NSDictionary *first = hosts.firstObject;
        self.hostLabel.text = [NSString stringWithFormat:@"Encontrado na rede: %@ (%@)", first[@"name"], first[@"ip"]];
    }
}

@end
