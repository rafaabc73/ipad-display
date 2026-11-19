#import "net_server.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static uint64_t net_now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
}

static BOOL sock_write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        // Chunk writes to <= 16KB so usbmuxd's AF_UNIX pseudo-TCP buffer never overflows!
        size_t chunk = len - sent;
        if (chunk > 16384) chunk = 16384;
        ssize_t n = send(fd, p + sent, chunk, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "[NetServer] sock_write_all erro (fd=%d, sent=%zu/%zu): %s\n", fd, sent, len, strerror(errno));
            return NO;
        }
        if (n == 0) return NO;
        sent += (size_t)n;
    }
    return YES;
}

static BOOL sock_read_all(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "[NetServer] sock_read_all erro (fd=%d): %s\n", fd, strerror(errno));
            return NO;
        }
        if (n == 0) return NO;
        got += (size_t)n;
    }
    return YES;
}

static void configure_client_socket(int fd, BOOL isUnixMux) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    if (!isUnixMux) {
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
        int sndBuf = 512 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndBuf, sizeof(sndBuf));
    }
    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static NSString *mime_type_for_path(NSString *path) {
    NSString *ext = [[path pathExtension] lowercaseString];
    if ([ext isEqualToString:@"html"]) return @"text/html; charset=utf-8";
    if ([ext isEqualToString:@"css"])  return @"text/css; charset=utf-8";
    if ([ext isEqualToString:@"js"])   return @"application/javascript; charset=utf-8";
    if ([ext isEqualToString:@"json"]) return @"application/json; charset=utf-8";
    if ([ext isEqualToString:@"png"])  return @"image/png";
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([ext isEqualToString:@"svg"])  return @"image/svg+xml";
    if ([ext isEqualToString:@"ico"])  return @"image/x-icon";
    return @"application/octet-stream";
}

#pragma mark - Client Session

@interface ClientSession : NSObject
@property (nonatomic) int fd;
@property (nonatomic) BOOL isWebSocket;
@property (nonatomic) uint8_t transport;      // IPD2_TRANSPORT_USB / WIFI
@property (nonatomic) uint32_t usbDeviceID;   // Non-zero for usbmuxd sockets
@property (nonatomic) uint8_t clientKind;     // IPD2_CLIENT_NATIVE_IOS / PWA_WEBGL
@property (nonatomic) uint8_t caps;
@property (nonatomic, copy) NSString *peerLabel;
@property (nonatomic, strong) dispatch_queue_t sendQueue;
@property (atomic) BOOL closed;
@property (atomic) int32_t pendingMotionFrames;
@property (atomic) int64_t queuedBytes;
@property (atomic) uint16_t rttTenthMs;
@property (atomic) uint64_t lastPingSentUs;
@property (atomic) BOOL sentH264Config;
@end

@implementation ClientSession

- (instancetype)initWithFd:(int)fd isWS:(BOOL)isWS transport:(uint8_t)transport label:(NSString *)label {
    self = [super init];
    if (self) {
        _fd = fd;
        _isWebSocket = isWS;
        _transport = transport;
        _peerLabel = label ?: @"iPad";
        _clientKind = isWS ? IPD2_CLIENT_PWA_WEBGL : IPD2_CLIENT_NATIVE_IOS;
        _caps = isWS ? (IPD2_CAP_LZ4_BGRA | IPD2_CAP_LZ4_RGB565) : (IPD2_CAP_H264 | IPD2_CAP_LZ4_BGRA);
        _sendQueue = dispatch_queue_create("ipd2.client.send", DISPATCH_QUEUE_SERIAL);
        _closed = NO;
        _pendingMotionFrames = 0;
        _queuedBytes = 0;
        _rttTenthMs = (transport == IPD2_TRANSPORT_USB) ? 8 : 50;
    }
    return self;
}

- (void)closeSession {
    if (self.closed) return;
    self.closed = YES;
    if (self.fd >= 0) {
        shutdown(self.fd, SHUT_RDWR);
        close(self.fd);
        self.fd = -1;
    }
}

- (BOOL)writeRawFrameType:(uint8_t)type flags:(uint8_t)flags extra:(uint16_t)extra seq:(uint32_t)seq payload:(const void *)payload len:(uint32_t)len {
    if (self.closed || self.fd < 0) return NO;

    IPD2Header hdr;
    ipd2_init_header(&hdr, type, flags, extra, seq, len);

    if (!self.isWebSocket) {
        if (!sock_write_all(self.fd, &hdr, sizeof(hdr))) return NO;
        if (len > 0 && payload) {
            if (!sock_write_all(self.fd, payload, len)) return NO;
        }
        return YES;
    } else {
        uint64_t totalLen = sizeof(hdr) + (uint64_t)len;
        uint8_t wsHdr[10];
        size_t wsHdrLen = 0;
        wsHdr[0] = 0x82; // FIN + Binary frame
        if (totalLen < 126) {
            wsHdr[1] = (uint8_t)totalLen;
            wsHdrLen = 2;
        } else if (totalLen <= 65535) {
            wsHdr[1] = 126;
            wsHdr[2] = (uint8_t)((totalLen >> 8) & 0xFF);
            wsHdr[3] = (uint8_t)(totalLen & 0xFF);
            wsHdrLen = 4;
        } else {
            wsHdr[1] = 127;
            wsHdr[2] = 0; wsHdr[3] = 0; wsHdr[4] = 0; wsHdr[5] = 0;
            wsHdr[6] = (uint8_t)((totalLen >> 24) & 0xFF);
            wsHdr[7] = (uint8_t)((totalLen >> 16) & 0xFF);
            wsHdr[8] = (uint8_t)((totalLen >> 8) & 0xFF);
            wsHdr[9] = (uint8_t)(totalLen & 0xFF);
            wsHdrLen = 10;
        }
        if (!sock_write_all(self.fd, wsHdr, wsHdrLen)) return NO;
        if (!sock_write_all(self.fd, &hdr, sizeof(hdr))) return NO;
        if (len > 0 && payload) {
            if (!sock_write_all(self.fd, payload, len)) return NO;
        }
        return YES;
    }
}

- (void)ackMotionFrame {
    if (_pendingMotionFrames > 0) {
        __sync_sub_and_fetch(&_pendingMotionFrames, 1);
    }
}

- (void)enqueuePacketType:(uint8_t)type
                    flags:(uint8_t)flags
                    extra:(uint16_t)extra
                      seq:(uint32_t)seq
                  payload:(NSData *)payload
                 droppable:(BOOL)droppable
                 isMotion:(BOOL)isMotion {
    if (self.closed) return;

    if (droppable) {
        if (isMotion && self.pendingMotionFrames >= 2) {
            return; // Strict backpressure: never let motion frames pile up!
        }
        if (self.queuedBytes > 2 * 1024 * 1024) {
            return;
        }
    }

    int64_t bytes = (int64_t)(sizeof(IPD2Header) + payload.length);
    __sync_add_and_fetch(&_queuedBytes, bytes);
    if (isMotion) {
        __sync_add_and_fetch(&_pendingMotionFrames, 1);
    }

    dispatch_async(self.sendQueue, ^{
        BOOL ok = [self writeRawFrameType:type
                                    flags:flags
                                    extra:extra
                                      seq:seq
                                  payload:payload.bytes
                                      len:(uint32_t)payload.length];
        __sync_sub_and_fetch(&self->_queuedBytes, bytes);
        if (!ok) {
            [self closeSession];
        }
    });
}

@end

#pragma mark - NetServer

@interface NetServer () <NSNetServiceDelegate> {
    uint32_t _seqCounter;
    NSData *_lastH264Config;
}
@property (nonatomic, copy) NSString *publicDir;
@property (nonatomic) uint16_t httpPort;
@property (nonatomic) uint16_t tcpPort;
@property (nonatomic) int httpListenFd;
@property (nonatomic) int tcpListenFd;
@property (atomic) BOOL running;

@property (nonatomic, strong, readwrite) CaptureEngine *captureEngine;
@property (nonatomic, strong, readwrite) InputInjector *inputInjector;
@property (nonatomic, strong, readwrite) USBMuxBridge *usbMux;

@property (nonatomic, strong) NSMutableArray<ClientSession *> *clients;
@property (nonatomic, strong) dispatch_queue_t clientsQueue;
@property (nonatomic, strong) dispatch_source_t pingTimer;
@property (nonatomic, strong) NSNetService *bonjourTcp;
@property (nonatomic, strong) NSNetService *bonjourHttp;
@end

@implementation NetServer

- (instancetype)initWithPublicDir:(NSString *)publicDir
                         httpPort:(uint16_t)httpPort
                          tcpPort:(uint16_t)tcpPort {
    self = [super init];
    if (self) {
        _publicDir = [publicDir copy];
        _httpPort = httpPort;
        _tcpPort = tcpPort;
        _httpListenFd = -1;
        _tcpListenFd = -1;
        _clients = [NSMutableArray array];
        _clientsQueue = dispatch_queue_create("ipd2.net.clients", DISPATCH_QUEUE_SERIAL);

        _captureEngine = [[CaptureEngine alloc] init];
        _captureEngine.delegate = self;

        _inputInjector = [[InputInjector alloc] init];

        _usbMux = [[USBMuxBridge alloc] initWithTargetPort:tcpPort];
        _usbMux.delegate = self;
    }
    return self;
}

- (int)createListenSocketOnPort:(uint16_t)port {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        fprintf(stderr, "[NetServer] Erro ao escutar na porta %u: %s\n", port, strerror(errno));
        close(fd);
        return -1;
    }
    if (listen(fd, 16) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

- (BOOL)start {
    if (self.running) return YES;

    self.httpListenFd = [self createListenSocketOnPort:self.httpPort];
    self.tcpListenFd  = [self createListenSocketOnPort:self.tcpPort];
    if (self.httpListenFd < 0 && self.tcpListenFd < 0) return NO;

    self.running = YES;

    // Accept loop for HTTP + WebSocket (PWA)
    if (self.httpListenFd >= 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            while (self.running) {
                struct sockaddr_in peer;
                socklen_t peerLen = sizeof(peer);
                int cfd = accept(self.httpListenFd, (struct sockaddr *)&peer, &peerLen);
                if (cfd < 0) {
                    if (!self.running) break;
                    continue;
                }
                char ipStr[INET_ADDRSTRLEN] = {0};
                inet_ntop(AF_INET, &peer.sin_addr, ipStr, sizeof(ipStr));
                NSString *ip = [NSString stringWithUTF8String:ipStr];
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    [self handleHTTPConnection:cfd peerIP:ip];
                });
            }
        });
    }

    // Accept loop for raw TCP (Native iOS App over Wi-Fi)
    if (self.tcpListenFd >= 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            while (self.running) {
                struct sockaddr_in peer;
                socklen_t peerLen = sizeof(peer);
                int cfd = accept(self.tcpListenFd, (struct sockaddr *)&peer, &peerLen);
                if (cfd < 0) {
                    if (!self.running) break;
                    continue;
                }
                char ipStr[INET_ADDRSTRLEN] = {0};
                inet_ntop(AF_INET, &peer.sin_addr, ipStr, sizeof(ipStr));
                NSString *ip = [NSString stringWithUTF8String:ipStr];
                uint8_t transport = ([ip hasPrefix:@"192.168.2."] || [ip hasPrefix:@"172.20.10."])
                                    ? IPD2_TRANSPORT_USB : IPD2_TRANSPORT_WIFI;
                [self registerClientFd:cfd isWS:NO transport:transport usbDeviceID:0 label:ip];
            }
        });
    }

    // Start usbmuxd automatic USB cable bridge
    [self.usbMux start];

    // Publish Bonjour services for automatic discovery on Wi-Fi
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *name = [[NSHost currentHost] localizedName] ?: @"iPad Display Mac";
        self.bonjourTcp = [[NSNetService alloc] initWithDomain:@"local." type:@"_ipaddisplay._tcp." name:name port:self.tcpPort];
        [self.bonjourTcp publish];
        self.bonjourHttp = [[NSNetService alloc] initWithDomain:@"local." type:@"_http._tcp." name:@"iPad Display" port:self.httpPort];
        [self.bonjourHttp publish];
    });

    // Periodic 2-second Ping for live RTT & DisplayInfo refresh
    __weak typeof(self) weakSelf = self;
    self.pingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.clientsQueue);
    dispatch_source_set_timer(self.pingTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.pingTimer, ^{
        NetServer *s = weakSelf;
        if (!s || !s.running) return;
        uint64_t ts = net_now_us();
        IPD2Ping ping = { ts };
        NSData *pingData = [NSData dataWithBytes:&ping length:sizeof(ping)];
        for (ClientSession *c in [s.clients copy]) {
            if (c.closed) continue;
            c.lastPingSentUs = ts;
            [c enqueuePacketType:IPD2_MSG_PING flags:0 extra:0 seq:0 payload:pingData droppable:YES isMotion:NO];

            IPD2DisplayInfo info;
            [s.captureEngine fillDisplayInfo:&info transport:c.transport rttTenthMs:c.rttTenthMs];
            NSData *infoData = [NSData dataWithBytes:&info length:sizeof(info)];
            [c enqueuePacketType:IPD2_MSG_DISPLAY_INFO flags:0 extra:0 seq:0 payload:infoData droppable:YES isMotion:NO];
        }
    });
    dispatch_resume(self.pingTimer);

    return YES;
}

- (void)stop {
    self.running = NO;
    [self.usbMux stop];
    if (self.pingTimer) { dispatch_source_cancel(self.pingTimer); self.pingTimer = nil; }
    if (self.httpListenFd >= 0) { shutdown(self.httpListenFd, SHUT_RDWR); close(self.httpListenFd); self.httpListenFd = -1; }
    if (self.tcpListenFd >= 0)  { shutdown(self.tcpListenFd, SHUT_RDWR); close(self.tcpListenFd); self.tcpListenFd = -1; }

    dispatch_sync(self.clientsQueue, ^{
        for (ClientSession *c in self.clients) {
            [c closeSession];
        }
        [self.clients removeAllObjects];
    });
    [self.captureEngine shutdown];
}

- (void)updateStatusDelegate {
    __block NSUInteger count = 0;
    __block BOOL hasUSB = NO;
    dispatch_sync(self.clientsQueue, ^{
        count = self.clients.count;
        for (ClientSession *c in self.clients) {
            if (c.transport == IPD2_TRANSPORT_USB) hasUSB = YES;
        }
    });

    NSString *modeStr = @"Aguardando iPad";
    if (count > 0) {
        NSString *m = (self.captureEngine.currentMode == IPD2_MODE_SECOND) ? @"Segunda Tela Retina"
                    : (self.captureEngine.currentMode == IPD2_MODE_MIRROR) ? @"Espelhando Tela"
                    : @"Conectado (Menu)";
        modeStr = [NSString stringWithFormat:@"%@ • %@", m, hasUSB ? @"Cabo USB" : @"Wi-Fi"];
    }
    id<NetServerStatusDelegate> del = self.statusDelegate;
    if (del) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [del netServerStatusDidChange:modeStr clientCount:count];
        });
    }
}

#pragma mark - USBMuxBridgeDelegate

- (void)usbMuxDidConnectSocket:(int)fd deviceID:(uint32_t)deviceID serial:(NSString *)serial {
    [self registerClientFd:fd isWS:NO transport:IPD2_TRANSPORT_USB usbDeviceID:deviceID label:[NSString stringWithFormat:@"USB:%@", serial]];
}

- (void)usbMuxDeviceListChanged:(NSUInteger)usbDeviceCount {
    [self updateStatusDelegate];
}

#pragma mark - Client Lifecycle & Read Loop

- (void)registerClientFd:(int)fd
                    isWS:(BOOL)isWS
               transport:(uint8_t)transport
             usbDeviceID:(uint32_t)usbDevID
                   label:(NSString *)label {
    configure_client_socket(fd, usbDevID != 0);
    ClientSession *session = [[ClientSession alloc] initWithFd:fd isWS:isWS transport:transport label:label];
    session.usbDeviceID = usbDevID;

    dispatch_sync(self.clientsQueue, ^{
        [self.clients addObject:session];
    });

    fprintf(stderr, "[NetServer] Cliente conectado: %s (%s, %s)\n",
            [label UTF8String],
            isWS ? "PWA WebGL" : "App Nativo iOS",
            transport == IPD2_TRANSPORT_USB ? "USB" : "Wi-Fi");

    // Immediately send DisplayInfo so client shows connected host name & live status
    IPD2DisplayInfo info;
    [self.captureEngine fillDisplayInfo:&info transport:session.transport rttTenthMs:session.rttTenthMs];
    NSData *infoData = [NSData dataWithBytes:&info length:sizeof(info)];
    [session enqueuePacketType:IPD2_MSG_DISPLAY_INFO flags:0 extra:0 seq:0 payload:infoData droppable:NO isMotion:NO];

    if (self.captureEngine.currentMode != IPD2_MODE_IDLE) {
        [self.captureEngine requestFullSync];
    }

    [self updateStatusDelegate];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (isWS) {
            [self readWebSocketLoop:session];
        } else {
            [self readRawTCPLoop:session];
        }

        [session closeSession];
        __block NSUInteger remaining = 0;
        dispatch_sync(self.clientsQueue, ^{
            [self.clients removeObject:session];
            remaining = self.clients.count;
        });

        fprintf(stderr, "[NetServer] Cliente desconectado: %s (Restantes: %lu)\n",
                [session.peerLabel UTF8String], (unsigned long)remaining);

        if (session.usbDeviceID != 0) {
            [self.usbMux notifySocketClosedForDeviceID:session.usbDeviceID];
        }

        // If all clients disconnected, automatically clean up virtual display after 3s grace period!
        if (remaining == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), self.clientsQueue, ^{
                if (self.clients.count == 0 && self.captureEngine.currentMode != IPD2_MODE_IDLE) {
                    fprintf(stderr, "[NetServer] Nenhum iPad conectado — desativando captura e tela virtual.\n");
                    [self.captureEngine setMode:IPD2_MODE_IDLE
                                         preset:self.captureEngine.currentPreset
                                       position:self.captureEngine.currentPosition];
                }
            });
        }
        [self updateStatusDelegate];
    });
}

- (void)readRawTCPLoop:(ClientSession *)session {
    while (!session.closed && self.running) {
        IPD2Header hdr;
        if (!sock_read_all(session.fd, &hdr, sizeof(hdr))) break;
        if (hdr.magic[0] != IPD2_MAGIC_0 || hdr.magic[1] != IPD2_MAGIC_1 ||
            hdr.magic[2] != IPD2_MAGIC_2 || hdr.magic[3] != IPD2_MAGIC_3) {
            break;
        }
        if (hdr.payloadLen > 1024 * 1024) break;
        NSMutableData *payload = nil;
        if (hdr.payloadLen > 0) {
            payload = [NSMutableData dataWithLength:hdr.payloadLen];
            if (!sock_read_all(session.fd, payload.mutableBytes, hdr.payloadLen)) break;
        }
        [self handleClientPacket:session header:&hdr payload:payload];
    }
}

- (void)readWebSocketLoop:(ClientSession *)session {
    NSMutableData *fragBuf = [NSMutableData data];
    while (!session.closed && self.running) {
        uint8_t b[2];
        if (!sock_read_all(session.fd, b, 2)) break;
        BOOL fin = (b[0] & 0x80) != 0;
        uint8_t opcode = b[0] & 0x0F;
        BOOL masked = (b[1] & 0x80) != 0;
        uint64_t plen = b[1] & 0x7F;

        if (plen == 126) {
            uint8_t ext[2];
            if (!sock_read_all(session.fd, ext, 2)) break;
            plen = ((uint64_t)ext[0] << 8) | ext[1];
        } else if (plen == 127) {
            uint8_t ext[8];
            if (!sock_read_all(session.fd, ext, 8)) break;
            plen = 0;
            for (int i = 0; i < 8; i++) plen = (plen << 8) | ext[i];
        }
        if (plen > 2 * 1024 * 1024) break;

        uint8_t maskKey[4] = {0};
        if (masked) {
            if (!sock_read_all(session.fd, maskKey, 4)) break;
        }

        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)plen];
        if (plen > 0) {
            if (!sock_read_all(session.fd, data.mutableBytes, (size_t)plen)) break;
            if (masked) {
                uint8_t *bytes = (uint8_t *)data.mutableBytes;
                for (uint64_t i = 0; i < plen; i++) {
                    bytes[i] ^= maskKey[i & 3];
                }
            }
        }

        if (opcode == 0x08) { // Close
            break;
        } else if (opcode == 0x09) { // Ping -> send Pong
            uint8_t pongLen = (uint8_t)(plen < 126 ? plen : 0);
            dispatch_async(session.sendQueue, ^{
                uint8_t pong[2] = { 0x8A, pongLen };
                sock_write_all(session.fd, pong, 2);
                if (pongLen > 0) sock_write_all(session.fd, data.bytes, pongLen);
            });
            continue;
        } else if (opcode == 0x0A) { // Pong
            continue;
        }

        if (opcode != 0x00) [fragBuf setLength:0];
        [fragBuf appendData:data];
        if (!fin) continue;

        if (fragBuf.length >= sizeof(IPD2Header)) {
            IPD2Header hdr;
            memcpy(&hdr, fragBuf.bytes, sizeof(hdr));
            if (hdr.magic[0] == IPD2_MAGIC_0 && hdr.magic[1] == IPD2_MAGIC_1 &&
                hdr.magic[2] == IPD2_MAGIC_2 && hdr.magic[3] == IPD2_MAGIC_3 &&
                fragBuf.length >= sizeof(IPD2Header) + hdr.payloadLen) {
                NSData *payload = (hdr.payloadLen > 0)
                    ? [fragBuf subdataWithRange:NSMakeRange(sizeof(IPD2Header), hdr.payloadLen)]
                    : nil;
                [self handleClientPacket:session header:&hdr payload:payload];
            }
        }
        [fragBuf setLength:0];
    }
}

- (void)handleClientPacket:(ClientSession *)session header:(const IPD2Header *)hdr payload:(NSData *)payload {
    switch (hdr->type) {
        case IPD2_MSG_HELLO: {
            if (payload.length >= sizeof(IPD2Hello)) {
                IPD2Hello hello;
                memcpy(&hello, payload.bytes, sizeof(hello));
                session.clientKind = hello.clientKind;
                session.caps = hello.caps;
                fprintf(stderr, "[NetServer] HELLO de %s: kind=%u caps=0x%02x tela=%ux%u @%ux\n",
                        [session.peerLabel UTF8String], hello.clientKind, hello.caps,
                        hello.screenW, hello.screenH, hello.scale);
                IPD2DisplayInfo info;
                [self.captureEngine fillDisplayInfo:&info transport:session.transport rttTenthMs:session.rttTenthMs];
                [session enqueuePacketType:IPD2_MSG_DISPLAY_INFO flags:0 extra:0 seq:0
                                   payload:[NSData dataWithBytes:&info length:sizeof(info)]
                                 droppable:NO isMotion:NO];
                if (self.captureEngine.currentMode != IPD2_MODE_IDLE) {
                    [self.captureEngine requestFullSync];
                }
            }
            break;
        }
        case IPD2_MSG_CONTROL: {
            if (payload.length >= sizeof(IPD2Control)) {
                IPD2Control ctrl;
                memcpy(&ctrl, payload.bytes, sizeof(ctrl));
                uint8_t mode = self.captureEngine.currentMode;
                uint8_t preset = self.captureEngine.currentPreset;
                uint8_t pos = self.captureEngine.currentPosition;

                if (ctrl.cmd == IPD2_CTRL_SET_MODE) {
                    mode = ctrl.arg1;
                    [self.captureEngine setMode:mode preset:preset position:pos];
                } else if (ctrl.cmd == IPD2_CTRL_SET_PRESET) {
                    preset = ctrl.arg1;
                    [self.captureEngine setMode:mode preset:preset position:pos];
                } else if (ctrl.cmd == IPD2_CTRL_SET_POSITION) {
                    pos = ctrl.arg1;
                    [self.captureEngine setMode:mode preset:preset position:pos];
                } else if (ctrl.cmd == IPD2_CTRL_REQUEST_SYNC) {
                    [self.captureEngine requestFullSync];
                }
                [self updateStatusDelegate];
            }
            break;
        }
        case IPD2_MSG_INPUT: {
            if (payload.length >= sizeof(IPD2Input)) {
                IPD2Input inp;
                memcpy(&inp, payload.bytes, sizeof(inp));
                self.inputInjector.targetDisplayID = self.captureEngine.activeDisplayID;
                [self.inputInjector handleInput:&inp];
            }
            break;
        }
        case IPD2_MSG_PING: {
            if (payload.length >= sizeof(IPD2Ping)) {
                [session enqueuePacketType:IPD2_MSG_PONG flags:0 extra:0 seq:hdr->seq
                                   payload:payload droppable:YES isMotion:NO];
            }
            break;
        }
        case IPD2_MSG_PONG: {
            if (payload.length >= sizeof(IPD2Ping)) {
                IPD2Ping p;
                memcpy(&p, payload.bytes, sizeof(p));
                uint64_t now = net_now_us();
                if (now >= p.timestampUs) {
                    uint64_t rttUs = now - p.timestampUs;
                    uint16_t tenthMs = (uint16_t)(rttUs / 100ULL);
                    if (tenthMs < 1) tenthMs = 1;
                    if (tenthMs > 9999) tenthMs = 9999;
                    session.rttTenthMs = tenthMs;
                }
            }
            break;
        }
        case IPD2_MSG_FRAME_ACK: {
            [session ackMotionFrame];
            break;
        }
        default:
            break;
    }
}

#pragma mark - HTTP & WebSocket Upgrade Handler

- (void)handleHTTPConnection:(int)fd peerIP:(NSString *)peerIP {
    configure_client_socket(fd, NO);

    char reqBuf[8192];
    size_t total = 0;
    BOOL headerEnd = NO;
    while (total < sizeof(reqBuf) - 1) {
        ssize_t n = recv(fd, reqBuf + total, sizeof(reqBuf) - 1 - total, 0);
        if (n <= 0) break;
        total += (size_t)n;
        reqBuf[total] = '\0';
        if (strstr(reqBuf, "\r\n\r\n") != NULL) {
            headerEnd = YES;
            break;
        }
    }

    if (!headerEnd || total == 0) {
        close(fd);
        return;
    }

    NSString *reqStr = [[NSString alloc] initWithBytes:reqBuf length:total encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [reqStr componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) { close(fd); return; }

    NSArray<NSString *> *reqLine = [lines[0] componentsSeparatedByString:@" "];
    if (reqLine.count < 2) { close(fd); return; }
    NSString *path = reqLine[1];
    NSRange qRange = [path rangeOfString:@"?"];
    if (qRange.location != NSNotFound) path = [path substringToIndex:qRange.location];

    // Parse headers
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *k = [[lines[i] substringToIndex:colon.location] lowercaseString];
            NSString *v = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            headers[k] = v;
        }
    }

    // WebSocket Upgrade (/ws)
    NSString *upgrade = [headers[@"upgrade"] lowercaseString];
    NSString *wsKey = headers[@"sec-websocket-key"];
    if ([path isEqualToString:@"/ws"] && [upgrade isEqualToString:@"websocket"] && wsKey.length > 0) {
        NSString *combined = [wsKey stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
        NSData *combData = [combined dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(combData.bytes, (CC_LONG)combData.length, digest);
        NSString *acceptKey = [[NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH] base64EncodedStringWithOptions:0];

        NSString *resp = [NSString stringWithFormat:
            @"HTTP/1.1 101 Switching Protocols\r\n"
             "Upgrade: websocket\r\n"
             "Connection: Upgrade\r\n"
             "Sec-WebSocket-Accept: %@\r\n\r\n", acceptKey];
        NSData *respData = [resp dataUsingEncoding:NSUTF8StringEncoding];
        if (!sock_write_all(fd, respData.bytes, respData.length)) {
            close(fd);
            return;
        }

        uint8_t transport = ([peerIP hasPrefix:@"192.168.2."] || [peerIP hasPrefix:@"172.20.10."])
                            ? IPD2_TRANSPORT_USB : IPD2_TRANSPORT_WIFI;
        [self registerClientFd:fd isWS:YES transport:transport usbDeviceID:0 label:peerIP];
        return;
    }

    // JSON Status API
    if ([path isEqualToString:@"/api/status"]) {
        __block NSUInteger cCount = 0;
        dispatch_sync(self.clientsQueue, ^{ cCount = self.clients.count; });
        NSDictionary *st = @{
            @"version": @"2.0",
            @"mode": @(self.captureEngine.currentMode),
            @"preset": @(self.captureEngine.currentPreset),
            @"fbWidth": @(self.captureEngine.fbWidth),
            @"fbHeight": @(self.captureEngine.fbHeight),
            @"fps": @(self.captureEngine.currentFPS),
            @"clients": @(cCount),
            @"usbDevices": @(self.usbMux.attachedDeviceCount),
            @"host": [[NSHost currentHost] localizedName] ?: @"Mac"
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:st options:0 error:nil];
        NSString *hdr = [NSString stringWithFormat:
            @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            (unsigned long)json.length];
        NSData *hData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
        sock_write_all(fd, hData.bytes, hData.length);
        sock_write_all(fd, json.bytes, json.length);
        close(fd);
        return;
    }

    // Static files from public/
    if ([path isEqualToString:@"/"]) path = @"/index.html";
    if ([path containsString:@".."]) { close(fd); return; }

    NSString *fullPath = [self.publicDir stringByAppendingPathComponent:[path substringFromIndex:1]];
    NSData *fileData = [NSData dataWithContentsOfFile:fullPath];
    if (!fileData) {
        const char *notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found";
        sock_write_all(fd, notFound, strlen(notFound));
        close(fd);
        return;
    }

    NSString *mime = mime_type_for_path(fullPath);
    NSString *hdr = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-cache, no-store, must-revalidate\r\nConnection: close\r\n\r\n",
        mime, (unsigned long)fileData.length];
    NSData *hData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    sock_write_all(fd, hData.bytes, hData.length);
    sock_write_all(fd, fileData.bytes, fileData.length);
    close(fd);
}

#pragma mark - CaptureEngineDelegate

- (BOOL)hasActiveClients {
    __block BOOL any = NO;
    dispatch_sync(self.clientsQueue, ^{ any = (self.clients.count > 0); });
    return any;
}

- (BOOL)hasH264Clients {
    __block BOOL any = NO;
    dispatch_sync(self.clientsQueue, ^{
        for (ClientSession *c in self.clients) {
            if (!c.closed && (c.caps & IPD2_CAP_H264)) { any = YES; break; }
        }
    });
    return any;
}

- (BOOL)hasTileOnlyClients {
    __block BOOL any = NO;
    dispatch_sync(self.clientsQueue, ^{
        for (ClientSession *c in self.clients) {
            if (!c.closed && !(c.caps & IPD2_CAP_H264)) { any = YES; break; }
        }
    });
    return any;
}

- (BOOL)canAcceptH264Frame {
    __block BOOL ready = NO;
    dispatch_sync(self.clientsQueue, ^{
        for (ClientSession *c in self.clients) {
            if (!c.closed && (c.caps & IPD2_CAP_H264) && c.pendingMotionFrames < 2) {
                ready = YES;
                break;
            }
        }
    });
    return ready;
}

- (void)captureEngineDidProduceTileBatch:(NSData *)packet
                                   flags:(uint8_t)flags
                               tileCount:(uint16_t)tileCount
                              toH264Only:(BOOL)h264Only
                            toTileOnly:(BOOL)tileOnly {
    BOOL isMotion = (flags & IPD2_TILE_FLAG_HALF_RES) != 0;
    uint32_t seq = __sync_add_and_fetch(&_seqCounter, 1);

    dispatch_async(self.clientsQueue, ^{
        for (ClientSession *c in self.clients) {
            if (c.closed) continue;
            BOOL isH264 = (c.caps & IPD2_CAP_H264) != 0;
            if (h264Only && !isH264) continue;
            if (tileOnly && isH264) continue;
            // Lossless Retina tiles are reliable (droppable=NO); half-res motion frames are droppable!
            [c enqueuePacketType:IPD2_MSG_TILE_BATCH
                           flags:flags
                           extra:tileCount
                             seq:seq
                         payload:packet
                       droppable:isMotion
                        isMotion:isMotion];
        }
    });
}

- (void)captureEngineDidProduceH264Config:(NSData *)configPayload {
    dispatch_async(self.clientsQueue, ^{
        self->_lastH264Config = configPayload;
        for (ClientSession *c in self.clients) {
            if (c.closed || !(c.caps & IPD2_CAP_H264)) continue;
            c.sentH264Config = YES;
            [c enqueuePacketType:IPD2_MSG_H264_CONFIG flags:0 extra:0 seq:0
                         payload:configPayload droppable:NO isMotion:NO];
        }
    });
}

- (void)captureEngineDidProduceH264Frame:(NSData *)framePayload isKeyframe:(BOOL)isKey {
    uint32_t seq = __sync_add_and_fetch(&_seqCounter, 1);
    uint8_t flags = isKey ? IPD2_H264_FLAG_KEYFRAME : 0;

    dispatch_async(self.clientsQueue, ^{
        for (ClientSession *c in self.clients) {
            if (c.closed || !(c.caps & IPD2_CAP_H264)) continue;
            if (!c.sentH264Config && self->_lastH264Config) {
                c.sentH264Config = YES;
                [c enqueuePacketType:IPD2_MSG_H264_CONFIG flags:0 extra:0 seq:0
                             payload:self->_lastH264Config droppable:NO isMotion:NO];
            }
            // NEVER drop an already-encoded H.264 P-frame (dropping breaks decoder ref frames -> colored blocks!)
            // Backpressure is cleanly gated BEFORE encoding via canAcceptH264Frame.
            [c enqueuePacketType:IPD2_MSG_H264_FRAME flags:flags extra:0 seq:seq
                         payload:framePayload droppable:NO isMotion:YES];
        }
    });
}

- (void)captureEngineDidUpdateCursor:(const IPD2Cursor *)cursor {
    NSData *data = [NSData dataWithBytes:cursor length:sizeof(IPD2Cursor)];
    dispatch_async(self.clientsQueue, ^{
        for (ClientSession *c in self.clients) {
            if (c.closed) continue;
            [c enqueuePacketType:IPD2_MSG_CURSOR flags:0 extra:0 seq:0
                         payload:data droppable:YES isMotion:NO];
        }
    });
}

- (void)captureEngineDidChangeDisplayInfo:(const IPD2DisplayInfo *)info {
    self.inputInjector.targetDisplayID = self.captureEngine.activeDisplayID;
    dispatch_async(self.clientsQueue, ^{
        for (ClientSession *c in self.clients) {
            if (c.closed) continue;
            IPD2DisplayInfo copy = *info;
            copy.transport = c.transport;
            copy.rttTenthMs = c.rttTenthMs;
            NSData *data = [NSData dataWithBytes:&copy length:sizeof(copy)];
            [c enqueuePacketType:IPD2_MSG_DISPLAY_INFO flags:0 extra:0 seq:0
                         payload:data droppable:NO isMotion:NO];
        }
    });
    [self updateStatusDelegate];
}

#pragma mark - Network Address Detection

- (NSArray<NSDictionary *> *)detectedAddresses {
    NSMutableArray *list = [NSMutableArray array];
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) == 0) {
        for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
            char buf[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
            NSString *ip = [NSString stringWithUTF8String:buf];
            NSString *iface = [NSString stringWithUTF8String:ifa->ifa_name];
            if ([ip isEqualToString:@"127.0.0.1"] || [ip hasPrefix:@"169.254."]) continue;
            BOOL isUSB = ([iface isEqualToString:@"bridge100"] || [ip hasPrefix:@"192.168.2."] || [ip hasPrefix:@"172.20.10."]);
            [list addObject:@{ @"iface": iface, @"ip": ip, @"type": isUSB ? @"usb" : @"wifi" }];
        }
        freeifaddrs(ifaddr);
    }
    return list;
}

- (void)printConnectionBanner {
    NSArray<NSDictionary *> *addrs = [self detectedAddresses];
    printf("\n=================================================================\n");
    printf("   🍏 iPad Display Pro v2.0 — Retina 2048x1536 & 60 FPS Nativo\n");
    printf("=================================================================\n");
    printf("  🔌 App Nativo iOS (Cabo USB Plug & Play via usbmuxd): ATIVO\n");
    printf("     → Basta conectar o cabo Lightning e abrir 'iPad Display' no iPad!\n");
    printf("  📶 App Nativo iOS (Wi-Fi Bonjour): porta TCP %u\n\n", self.tcpPort);
    printf("  🌐 App Web / PWA Retina (WebGL + LZ4 Lossless, sem expiração):\n");
    for (NSDictionary *a in addrs) {
        BOOL isUSB = [a[@"type"] isEqualToString:@"usb"];
        printf("     %s http://%s:%u  (%s)\n",
               isUSB ? "⚡ USB  :" : "📶 Wi-Fi:",
               [a[@"ip"] UTF8String], self.httpPort, [a[@"iface"] UTF8String]);
    }
    printf("=================================================================\n\n");
    fflush(stdout);
}

@end
