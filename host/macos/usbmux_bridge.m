#import "usbmux_bridge.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>

typedef struct __attribute__((packed)) {
    uint32_t length;
    uint32_t version;
    uint32_t message;
    uint32_t tag;
} USBMuxHeader;

static int open_usbmux_socket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, "/var/run/usbmuxd", sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static BOOL read_exact(int fd, void *buf, size_t len) {
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

static BOOL write_exact(int fd, const void *buf, size_t len) {
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

static BOOL send_usbmux_plist(int fd, NSDictionary *dict, uint32_t tag) {
    NSError *err = nil;
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:dict
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:&err];
    if (!xml || err) return NO;

    USBMuxHeader hdr;
    hdr.length  = (uint32_t)(sizeof(USBMuxHeader) + xml.length);
    hdr.version = 1;
    hdr.message = 8; // plist message
    hdr.tag     = tag;

    if (!write_exact(fd, &hdr, sizeof(hdr))) return NO;
    return write_exact(fd, xml.bytes, xml.length);
}

static NSDictionary *recv_usbmux_plist(int fd) {
    USBMuxHeader hdr;
    if (!read_exact(fd, &hdr, sizeof(hdr))) return nil;
    if (hdr.length < sizeof(USBMuxHeader) || hdr.length > 2 * 1024 * 1024) return nil;

    size_t payloadLen = hdr.length - sizeof(USBMuxHeader);
    NSMutableData *data = [NSMutableData dataWithLength:payloadLen];
    if (!read_exact(fd, data.mutableBytes, payloadLen)) return nil;

    NSError *err = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:&err];
    return [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)obj : nil;
}

@interface USBMuxBridge ()
@property (nonatomic) uint16_t targetPort;
@property (atomic) BOOL running;
@property (nonatomic) int listenFd;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *attachedDevices;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *connectedDevices;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@end

@implementation USBMuxBridge

- (instancetype)initWithTargetPort:(uint16_t)port {
    self = [super init];
    if (self) {
        _targetPort = port;
        _listenFd = -1;
        _attachedDevices = [NSMutableDictionary dictionary];
        _connectedDevices = [NSMutableSet set];
        _stateQueue = dispatch_queue_create("ipd2.usbmux.state", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSUInteger)attachedDeviceCount {
    __block NSUInteger c = 0;
    dispatch_sync(self.stateQueue, ^{
        c = self.attachedDevices.count;
    });
    return c;
}

- (void)start {
    if (self.running) return;
    self.running = YES;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self listenLoop];
    });
}

- (void)stop {
    self.running = NO;
    if (self.listenFd >= 0) {
        shutdown(self.listenFd, SHUT_RDWR);
        close(self.listenFd);
        self.listenFd = -1;
    }
}

- (void)notifySocketClosedForDeviceID:(uint32_t)deviceID {
    NSNumber *key = @(deviceID);
    dispatch_async(self.stateQueue, ^{
        [self.connectedDevices removeObject:key];
        NSString *serial = self.attachedDevices[key];
        if (serial && self.running) {
            [self spawnConnectorForDeviceID:deviceID serial:serial];
        }
    });
}

- (void)listenLoop {
    while (self.running) {
        int fd = open_usbmux_socket();
        if (fd < 0) {
            usleep(1500000);
            continue;
        }
        self.listenFd = fd;

        NSDictionary *listenMsg = @{
            @"MessageType": @"Listen",
            @"ClientVersionString": @"iPadDisplay-2.0",
            @"ProgName": @"iPadDisplay"
        };
        if (!send_usbmux_plist(fd, listenMsg, 1)) {
            close(fd);
            self.listenFd = -1;
            usleep(1000000);
            continue;
        }

        // First response is Result for Listen
        NSDictionary *res = recv_usbmux_plist(fd);
        if (!res) {
            close(fd);
            self.listenFd = -1;
            usleep(1000000);
            continue;
        }

        fprintf(stderr, "[USBMux] Monitorando conexões USB de iPad em /var/run/usbmuxd...\n");

        while (self.running) {
            NSDictionary *ev = recv_usbmux_plist(fd);
            if (!ev) break;

            NSString *msgType = ev[@"MessageType"];
            if ([msgType isEqualToString:@"Attached"]) {
                NSDictionary *props = ev[@"Properties"];
                NSString *connType = props[@"ConnectionType"];
                if (connType && ![connType isEqualToString:@"USB"]) {
                    continue; // Only care about physical USB cable here
                }
                uint32_t devID = [ev[@"DeviceID"] unsignedIntValue];
                NSString *serial = props[@"SerialNumber"] ?: @"iPad-USB";
                NSNumber *key = @(devID);

                dispatch_async(self.stateQueue, ^{
                    self.attachedDevices[key] = serial;
                    NSUInteger count = self.attachedDevices.count;
                    fprintf(stderr, "[USBMux] iPad detectado no cabo USB! DeviceID=%u Serial=%s\n",
                            devID, [serial UTF8String]);
                    [self.delegate usbMuxDeviceListChanged:count];
                    if (![self.connectedDevices containsObject:key]) {
                        [self spawnConnectorForDeviceID:devID serial:serial];
                    }
                });
            } else if ([msgType isEqualToString:@"Detached"]) {
                uint32_t devID = [ev[@"DeviceID"] unsignedIntValue];
                NSNumber *key = @(devID);
                dispatch_async(self.stateQueue, ^{
                    [self.attachedDevices removeObjectForKey:key];
                    [self.connectedDevices removeObject:key];
                    NSUInteger count = self.attachedDevices.count;
                    fprintf(stderr, "[USBMux] Cabo USB desconectado (DeviceID=%u)\n", devID);
                    [self.delegate usbMuxDeviceListChanged:count];
                });
            }
        }

        close(fd);
        self.listenFd = -1;
        if (self.running) usleep(1000000);
    }
}

- (void)spawnConnectorForDeviceID:(uint32_t)deviceID serial:(NSString *)serial {
    NSNumber *key = @(deviceID);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (self.running) {
            __block BOOL shouldContinue = NO;
            dispatch_sync(self.stateQueue, ^{
                shouldContinue = (self.attachedDevices[key] != nil) &&
                                 ![self.connectedDevices containsObject:key];
            });
            if (!shouldContinue) return;

            int fd = open_usbmux_socket();
            if (fd < 0) {
                usleep(1000000);
                continue;
            }

            // usbmuxd expects PortNumber in network byte order (big-endian)
            uint16_t portNet = htons(self.targetPort);
            NSDictionary *connectMsg = @{
                @"MessageType": @"Connect",
                @"DeviceID": @(deviceID),
                @"PortNumber": @(portNet),
                @"ClientVersionString": @"iPadDisplay-2.0",
                @"ProgName": @"iPadDisplay"
            };

            if (send_usbmux_plist(fd, connectMsg, 2)) {
                NSDictionary *reply = recv_usbmux_plist(fd);
                if (reply && [reply[@"MessageType"] isEqualToString:@"Result"] &&
                    [reply[@"Number"] intValue] == 0) {
                    __block BOOL accepted = NO;
                    dispatch_sync(self.stateQueue, ^{
                        if (self.attachedDevices[key] != nil && ![self.connectedDevices containsObject:key]) {
                            [self.connectedDevices addObject:key];
                            accepted = YES;
                        }
                    });
                    if (accepted) {
                        fprintf(stderr, "[USBMux] Túnel USB 480Mbps conectado ao app do iPad (porta %u)!\n",
                                self.targetPort);
                        [self.delegate usbMuxDidConnectSocket:fd deviceID:deviceID serial:serial];
                        return; // Connector exits; restarts when notifySocketClosedForDeviceID is called
                    }
                }
            }

            close(fd);
            usleep(800000); // Wait 800ms before retrying until user opens the iPad app
        }
    });
}

@end
