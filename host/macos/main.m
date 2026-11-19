#import <Cocoa/Cocoa.h>
#import "net_server.h"
#import "../../shared/protocol.h"
#include <signal.h>
#include <stdio.h>

static NetServer *gServer = nil;

@interface MenuBarDelegate : NSObject <NSApplicationDelegate, NetServerStatusDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *statusLabelItem;
@property (nonatomic, strong) NSMenuItem *usbInfoItem;
@property (nonatomic, strong) NSMenuItem *wifiInfoItem;
@property (nonatomic, strong) NetServer *server;
@end

@implementation MenuBarDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
    }
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    if (@available(macOS 11.0, *)) {
        NSImage *img = [NSImage imageWithSystemSymbolName:@"ipad.landscape" accessibilityDescription:@"iPad Display"];
        [img setTemplate:YES];
        self.statusItem.button.image = img;
    } else {
        self.statusItem.button.title = @"iPad";
    }
    self.statusItem.button.toolTip = @"iPad Display Pro";

    [self rebuildMenuWithStatus:@"Aguardando iPad..."];
}

- (void)rebuildMenuWithStatus:(NSString *)statusText {
    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *title = [[NSMenuItem alloc] initWithTitle:@"iPad Display Pro v2.0" action:nil keyEquivalent:@""];
    title.enabled = NO;
    [menu addItem:title];

    self.statusLabelItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"● %@", statusText] action:nil keyEquivalent:@""];
    self.statusLabelItem.enabled = NO;
    [menu addItem:self.statusLabelItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Mode shortcuts
    NSMenuItem *mSecond = [[NSMenuItem alloc] initWithTitle:@"Ativar Segunda Tela (Retina 2048×1536)" action:@selector(actionSecond:) keyEquivalent:@""];
    mSecond.target = self;
    [menu addItem:mSecond];

    NSMenuItem *mMirror = [[NSMenuItem alloc] initWithTitle:@"Ativar Espelhamento" action:@selector(actionMirror:) keyEquivalent:@""];
    mMirror.target = self;
    [menu addItem:mMirror];

    NSMenuItem *mIdle = [[NSMenuItem alloc] initWithTitle:@"Desativar Monitor Virtual" action:@selector(actionIdle:) keyEquivalent:@""];
    mIdle.target = self;
    [menu addItem:mIdle];

    [menu addItem:[NSMenuItem separatorItem]];

    // Position submenu
    NSMenuItem *posItem = [[NSMenuItem alloc] initWithTitle:@"Posição da Segunda Tela" action:nil keyEquivalent:@""];
    NSMenu *posMenu = [[NSMenu alloc] init];
    NSArray *posNames = @[ @"À Direita do Mac", @"À Esquerda do Mac", @"Acima do Mac", @"Abaixo do Mac" ];
    for (NSInteger i = 0; i < (NSInteger)posNames.count; i++) {
        NSMenuItem *pi = [[NSMenuItem alloc] initWithTitle:posNames[i] action:@selector(actionPosition:) keyEquivalent:@""];
        pi.target = self;
        pi.tag = i;
        if (self.server.captureEngine.currentPosition == (uint8_t)i) pi.state = NSControlStateValueOn;
        [posMenu addItem:pi];
    }
    posItem.submenu = posMenu;
    [menu addItem:posItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Copy PWA URLs
    NSArray<NSDictionary *> *addrs = [self.server detectedAddresses];
    for (NSDictionary *a in addrs) {
        BOOL isUSB = [a[@"type"] isEqualToString:@"usb"];
        NSString *url = [NSString stringWithFormat:@"http://%@:%u", a[@"ip"], IPD2_HTTP_PORT];
        NSString *label = [NSString stringWithFormat:@"Copiar URL %@: %@", isUSB ? @"USB" : @"Wi-Fi", url];
        NSMenuItem *uItem = [[NSMenuItem alloc] initWithTitle:label action:@selector(actionCopyURL:) keyEquivalent:@""];
        uItem.target = self;
        uItem.representedObject = url;
        [menu addItem:uItem];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Encerrar iPad Display" action:@selector(actionQuit:) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (void)netServerStatusDidChange:(NSString *)statusText clientCount:(NSUInteger)count {
    [self rebuildMenuWithStatus:statusText];
}

- (void)actionSecond:(id)sender {
    [self.server.captureEngine setMode:IPD2_MODE_SECOND
                                preset:self.server.captureEngine.currentPreset
                              position:self.server.captureEngine.currentPosition];
}

- (void)actionMirror:(id)sender {
    [self.server.captureEngine setMode:IPD2_MODE_MIRROR
                                preset:self.server.captureEngine.currentPreset
                              position:self.server.captureEngine.currentPosition];
}

- (void)actionIdle:(id)sender {
    [self.server.captureEngine setMode:IPD2_MODE_IDLE
                                preset:self.server.captureEngine.currentPreset
                              position:self.server.captureEngine.currentPosition];
}

- (void)actionPosition:(NSMenuItem *)sender {
    uint8_t pos = (uint8_t)sender.tag;
    [self.server.captureEngine setMode:self.server.captureEngine.currentMode
                                preset:self.server.captureEngine.currentPreset
                              position:pos];
    [self rebuildMenuWithStatus:self.statusLabelItem.title ?: @"Ativo"];
}

- (void)actionCopyURL:(NSMenuItem *)sender {
    NSString *url = sender.representedObject;
    if (url) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:url forType:NSPasteboardTypeString];
    }
}

- (void)actionQuit:(id)sender {
    [self.server stop];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.server stop];
}

@end

static NSString *resolve_public_dir(const char *argv0, NSString *overrideDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (overrideDir.length > 0 && [fm fileExistsAtPath:overrideDir]) return overrideDir;

    // 1. Inside .app bundle Resources/public
    NSString *resPath = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"public"];
    if (resPath && [fm fileExistsAtPath:resPath]) return resPath;

    // 2. Relative to binary (../public)
    NSString *binDir = [[NSString stringWithUTF8String:argv0] stringByDeletingLastPathComponent];
    NSString *relPublic = [[binDir stringByAppendingPathComponent:@"../public"] stringByStandardizingPath];
    if ([fm fileExistsAtPath:relPublic]) return relPublic;

    // 3. Current working directory ./public
    NSString *cwdPublic = [[fm currentDirectoryPath] stringByAppendingPathComponent:@"public"];
    if ([fm fileExistsAtPath:cwdPublic]) return cwdPublic;

    return cwdPublic;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);

        BOOL headless = NO;
        uint16_t httpPort = IPD2_HTTP_PORT;
        uint16_t tcpPort  = IPD2_TCP_PORT;
        NSString *publicOverride = nil;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--headless") == 0) {
                headless = YES;
            } else if (strcmp(argv[i], "--http-port") == 0 && i + 1 < argc) {
                httpPort = (uint16_t)atoi(argv[++i]);
            } else if (strcmp(argv[i], "--tcp-port") == 0 && i + 1 < argc) {
                tcpPort = (uint16_t)atoi(argv[++i]);
            } else if (strcmp(argv[i], "--public") == 0 && i + 1 < argc) {
                publicOverride = [NSString stringWithUTF8String:argv[++i]];
            }
        }

        NSString *publicDir = resolve_public_dir(argv[0], publicOverride);
        gServer = [[NetServer alloc] initWithPublicDir:publicDir httpPort:httpPort tcpPort:tcpPort];

        if (![gServer start]) {
            fprintf(stderr, "[Main] Falha ao iniciar servidor nas portas %u / %u.\n", httpPort, tcpPort);
            return 1;
        }
        [gServer printConnectionBanner];

        // Safe GCD signal handling (cleanly removes virtual display on Ctrl+C)
        signal(SIGINT, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t sigInt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigInt, ^{
            fprintf(stderr, "\n[Main] Encerrando e removendo monitor virtual...\n");
            [gServer stop];
            exit(0);
        });
        dispatch_resume(sigInt);

        dispatch_source_t sigTerm = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigTerm, ^{
            fprintf(stderr, "\n[Main] Encerrando (SIGTERM)...\n");
            [gServer stop];
            exit(0);
        });
        dispatch_resume(sigTerm);

        if (headless) {
            [[NSRunLoop currentRunLoop] run];
        } else {
            NSApplication *app = [NSApplication sharedApplication];
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
            MenuBarDelegate *del = [[MenuBarDelegate alloc] init];
            del.server = gServer;
            gServer.statusDelegate = del;
            app.delegate = del;
            [app run];
        }
    }
    return 0;
}
