#import "ConnectionManager.h"
#import <UIKit/UIKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>

static BOOL ios_write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) return NO;
        sent += (size_t)n;
    }
    return YES;
}

static BOOL ios_read_all(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) return NO;
        got += (size_t)n;
    }
    return YES;
}

static void ios_tune_socket(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    int rcvBuf = 2 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, sizeof(rcvBuf));
}

@interface ConnectionManager () <NSNetServiceBrowserDelegate, NSNetServiceDelegate> {
    int _listenFd;
    int _activeFd;
    uint32_t _sessionGen;
}
@property (atomic) BOOL running;
@property (nonatomic, readwrite) BOOL isConnected;
@property (nonatomic, readwrite) uint8_t activeTransport;
@property (nonatomic, readwrite) IPD2DisplayInfo lastDisplayInfo;
@property (nonatomic, strong) dispatch_queue_t sendQueue;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) NSNetServiceBrowser *bonjourBrowser;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *resolvingServices;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *discoveredHosts;
@end

@implementation ConnectionManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFd = -1;
        _activeFd = -1;
        _sendQueue = dispatch_queue_create("ipd2.ios.send", DISPATCH_QUEUE_SERIAL);
        _stateQueue = dispatch_queue_create("ipd2.ios.connstate", DISPATCH_QUEUE_SERIAL);
        _resolvingServices = [NSMutableArray array];
        _discoveredHosts = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (self.running) return;
    self.running = YES;
    [self startUSBListener];
    [self startBonjourDiscovery];
}

- (void)stop {
    self.running = NO;
    if (_listenFd >= 0) {
        shutdown(_listenFd, SHUT_RDWR);
        close(_listenFd);
        _listenFd = -1;
    }
    dispatch_sync(self.stateQueue, ^{
        if (self->_activeFd >= 0) {
            shutdown(self->_activeFd, SHUT_RDWR);
            close(self->_activeFd);
            self->_activeFd = -1;
        }
        self.isConnected = NO;
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.bonjourBrowser stop];
        self.bonjourBrowser = nil;
    });
}

#pragma mark - Local TCP Listener (Receives usbmuxd USB Tunnel from ANY Mac/Windows/Linux PC!)

- (void)startUSBListener {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(IPD2_TCP_PORT);

        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
            close(fd);
            return;
        }
        self->_listenFd = fd;

        while (self.running) {
            struct sockaddr_in peer;
            socklen_t peerLen = sizeof(peer);
            int cfd = accept(fd, (struct sockaddr *)&peer, &peerLen);
            if (cfd < 0) {
                if (!self.running) break;
                continue;
            }
            // usbmuxd connections arrive from loopback (127.0.0.1) on iOS!
            char ipBuf[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &peer.sin_addr, ipBuf, sizeof(ipBuf));
            NSString *peerIP = [NSString stringWithUTF8String:ipBuf];
            BOOL isUSB = ([peerIP isEqualToString:@"127.0.0.1"] || [peerIP hasPrefix:@"192.168.2."]);
            [self adoptSocket:cfd transport:(isUSB ? IPD2_TRANSPORT_USB : IPD2_TRANSPORT_WIFI)
                        label:(isUSB ? @"Cabo USB" : peerIP)];
        }
    });
}

#pragma mark - Wi-Fi Bonjour Auto-Discovery

- (void)startBonjourDiscovery {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.bonjourBrowser = [[NSNetServiceBrowser alloc] init];
        self.bonjourBrowser.delegate = self;
        [self.bonjourBrowser searchForServicesOfType:@"_ipaddisplay._tcp." inDomain:@"local."];
    });
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    [self.resolvingServices addObject:service];
    service.delegate = self;
    [service resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing {
    [self.resolvingServices removeObject:service];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSDictionary *h in self.discoveredHosts) {
        if (![h[@"name"] isEqualToString:service.name]) [keep addObject:h];
    }
    self.discoveredHosts = keep;
    [self.delegate connectionDidUpdateDiscoveredHosts:[self.discoveredHosts copy]];
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    NSString *resolvedIP = nil;
    for (NSData *addrData in sender.addresses) {
        const struct sockaddr *sa = (const struct sockaddr *)addrData.bytes;
        if (sa->sa_family == AF_INET) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
            char buf[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
            resolvedIP = [NSString stringWithUTF8String:buf];
            break;
        }
    }
    if (!resolvedIP) return;

    NSDictionary *entry = @{ @"name": sender.name ?: @"Computador", @"ip": resolvedIP, @"port": @(sender.port) };
    BOOL exists = NO;
    for (NSDictionary *h in self.discoveredHosts) {
        if ([h[@"ip"] isEqualToString:resolvedIP]) { exists = YES; break; }
    }
    if (!exists) {
        [self.discoveredHosts addObject:entry];
        [self.delegate connectionDidUpdateDiscoveredHosts:[self.discoveredHosts copy]];
    }

    // Auto-connect over Wi-Fi if not already connected via USB!
    if (!self.isConnected) {
        [self connectToManualHost:resolvedIP port:(uint16_t)sender.port];
    }
}

- (void)connectToManualHost:(NSString *)host port:(uint16_t)port {
    if (host.length == 0) return;
    if (port == 0) port = IPD2_TCP_PORT;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        struct addrinfo hints, *res = NULL;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        char portStr[16];
        snprintf(portStr, sizeof(portStr), "%u", port);
        if (getaddrinfo([host UTF8String], portStr, &hints, &res) != 0 || !res) return;

        int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (fd < 0) { freeaddrinfo(res); return; }

        struct timeval tv = { .tv_sec = 4, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
            close(fd);
            freeaddrinfo(res);
            return;
        }
        freeaddrinfo(res);

        // Reset timeout to normal streaming operation
        struct timeval noTimeout = { .tv_sec = 10, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &noTimeout, sizeof(noTimeout));

        BOOL isUSB = ([host hasPrefix:@"192.168.2."] || [host hasPrefix:@"172.20.10."]);
        [self adoptSocket:fd transport:(isUSB ? IPD2_TRANSPORT_USB : IPD2_TRANSPORT_WIFI) label:host];
    });
}

#pragma mark - Active Session Handling

- (void)adoptSocket:(int)fd transport:(uint8_t)transport label:(NSString *)label {
    ios_tune_socket(fd);

    __block uint32_t myGen = 0;
    dispatch_sync(self.stateQueue, ^{
        // USB cable always takes priority over Wi-Fi!
        if (self->_activeFd >= 0) {
            if (self.activeTransport == IPD2_TRANSPORT_USB && transport != IPD2_TRANSPORT_USB) {
                close(fd);
                myGen = 0;
                return;
            }
            shutdown(self->_activeFd, SHUT_RDWR);
            close(self->_activeFd);
        }
        self->_activeFd = fd;
        self->_sessionGen++;
        myGen = self->_sessionGen;
        self.activeTransport = transport;
        self.isConnected = YES;
    });
    if (myGen == 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate connectionDidConnectViaTransport:transport peerLabel:label];
    });

    [self sendHello];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self readLoopForFd:fd generation:myGen];
    });
}

- (void)readLoopForFd:(int)fd generation:(uint32_t)gen {
    while (self.running) {
        IPD2Header hdr;
        if (!ios_read_all(fd, &hdr, sizeof(hdr))) break;
        if (hdr.magic[0] != IPD2_MAGIC_0 || hdr.magic[1] != IPD2_MAGIC_1 ||
            hdr.magic[2] != IPD2_MAGIC_2 || hdr.magic[3] != IPD2_MAGIC_3) {
            break;
        }
        if (hdr.payloadLen > 16 * 1024 * 1024) break;

        NSMutableData *payload = nil;
        if (hdr.payloadLen > 0) {
            payload = [NSMutableData dataWithLength:hdr.payloadLen];
            if (!ios_read_all(fd, payload.mutableBytes, hdr.payloadLen)) break;
        }

        switch (hdr.type) {
            case IPD2_MSG_DISPLAY_INFO: {
                if (payload.length >= sizeof(IPD2DisplayInfo)) {
                    IPD2DisplayInfo info;
                    memcpy(&info, payload.bytes, sizeof(info));
                    self.lastDisplayInfo = info;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate connectionDidReceiveDisplayInfo:info];
                    });
                }
                break;
            }
            case IPD2_MSG_TILE_BATCH: {
                if (payload) {
                    [self.delegate connectionDidReceiveTileBatch:payload
                                                           flags:hdr.flags
                                                       tileCount:hdr.extra
                                                             seq:hdr.seq];
                }
                break;
            }
            case IPD2_MSG_H264_CONFIG: {
                if (payload) {
                    [self.delegate connectionDidReceiveH264Config:payload];
                }
                break;
            }
            case IPD2_MSG_H264_FRAME: {
                if (payload) {
                    BOOL isKey = (hdr.flags & IPD2_H264_FLAG_KEYFRAME) != 0;
                    [self.delegate connectionDidReceiveH264Frame:payload isKeyframe:isKey seq:hdr.seq];
                }
                break;
            }
            case IPD2_MSG_CURSOR: {
                if (payload.length >= sizeof(IPD2Cursor)) {
                    IPD2Cursor cur;
                    memcpy(&cur, payload.bytes, sizeof(cur));
                    [self.delegate connectionDidReceiveCursor:cur];
                }
                break;
            }
            case IPD2_MSG_PING: {
                if (payload.length >= sizeof(IPD2Ping)) {
                    [self sendPacketType:IPD2_MSG_PONG flags:0 extra:0 seq:hdr.seq payload:payload];
                }
                break;
            }
            default:
                break;
        }
    }

    __block BOOL wasCurrent = NO;
    dispatch_sync(self.stateQueue, ^{
        if (self->_sessionGen == gen && self->_activeFd == fd) {
            shutdown(fd, SHUT_RDWR);
            close(fd);
            self->_activeFd = -1;
            self.isConnected = NO;
            wasCurrent = YES;
        }
    });

    if (wasCurrent) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate connectionDidDisconnect];
        });
    }
}

#pragma mark - Outgoing Packets

- (void)sendPacketType:(uint8_t)type flags:(uint8_t)flags extra:(uint16_t)extra seq:(uint32_t)seq payload:(NSData *)payload {
    dispatch_async(self.sendQueue, ^{
        __block int fd = -1;
        dispatch_sync(self.stateQueue, ^{ fd = self->_activeFd; });
        if (fd < 0) return;

        IPD2Header hdr;
        ipd2_init_header(&hdr, type, flags, extra, seq, (uint32_t)payload.length);
        if (!ios_write_all(fd, &hdr, sizeof(hdr))) return;
        if (payload.length > 0) {
            ios_write_all(fd, payload.bytes, payload.length);
        }
    });
}

- (void)sendHello {
    UIScreen *scr = [UIScreen mainScreen];
    CGFloat scale = scr.scale;
    CGSize sz = scr.bounds.size;
    uint16_t maxSide = (uint16_t)(MAX(sz.width, sz.height) * scale);
    uint16_t minSide = (uint16_t)(MIN(sz.width, sz.height) * scale);

    IPD2Hello h;
    memset(&h, 0, sizeof(h));
    h.clientKind = IPD2_CLIENT_NATIVE_IOS;
    h.caps = IPD2_CAP_H264 | IPD2_CAP_LZ4_BGRA;
    h.screenW = maxSide;
    h.screenH = minSide;
    h.maxH264W = 1920; // Safe A6X hardware H.264 cap
    h.maxH264H = 1080;
    h.scale = (uint8_t)scale;

    [self sendPacketType:IPD2_MSG_HELLO flags:0 extra:0 seq:0
                 payload:[NSData dataWithBytes:&h length:sizeof(h)]];
}

- (void)sendControlCmd:(uint8_t)cmd arg1:(uint8_t)arg1 {
    IPD2Control c;
    memset(&c, 0, sizeof(c));
    c.cmd = cmd;
    c.arg1 = arg1;
    [self sendPacketType:IPD2_MSG_CONTROL flags:0 extra:0 seq:0
                 payload:[NSData dataWithBytes:&c length:sizeof(c)]];
}

- (void)sendInput:(IPD2Input)input {
    [self sendPacketType:IPD2_MSG_INPUT flags:0 extra:0 seq:0
                 payload:[NSData dataWithBytes:&input length:sizeof(input)]];
}

- (void)sendFrameAck:(uint32_t)seq {
    IPD2FrameAck ack = { seq };
    [self sendPacketType:IPD2_MSG_FRAME_ACK flags:0 extra:0 seq:0
                 payload:[NSData dataWithBytes:&ack length:sizeof(ack)]];
}

@end
