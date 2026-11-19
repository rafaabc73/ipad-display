#ifndef IPD2_PROTOCOL_H
#define IPD2_PROTOCOL_H

#include <stdint.h>

#define IPD2_MAGIC_0 'I'
#define IPD2_MAGIC_1 'P'
#define IPD2_MAGIC_2 'D'
#define IPD2_MAGIC_3 '2'

#define IPD2_TCP_PORT  23456
#define IPD2_HTTP_PORT 8080

// Message Types
enum IPD2MessageType {
    IPD2_MSG_HELLO        = 0x01, // Client -> Host
    IPD2_MSG_DISPLAY_INFO = 0x02, // Host -> Client
    IPD2_MSG_H264_CONFIG  = 0x03, // Host -> Client (SPS/PPS)
    IPD2_MSG_H264_FRAME   = 0x04, // Host -> Client (AVCC NAL units)
    IPD2_MSG_TILE_BATCH   = 0x05, // Host -> Client (Dirty tiles: LZ4 BGRA / RGB565 / RAW)
    IPD2_MSG_CURSOR       = 0x06, // Host -> Client (60Hz independent cursor)
    IPD2_MSG_INPUT        = 0x07, // Client -> Host (Touch/Mouse/Scroll/Key)
    IPD2_MSG_CONTROL      = 0x08, // Client -> Host (Mode/Preset/Position/Sync)
    IPD2_MSG_PING         = 0x09, // Bidirectional RTT check
    IPD2_MSG_PONG         = 0x0A, // Bidirectional RTT reply
    IPD2_MSG_FRAME_ACK    = 0x0B  // Client -> Host (End-to-end flow control)
};

// Client kinds
enum IPD2ClientKind {
    IPD2_CLIENT_NATIVE_IOS = 1,
    IPD2_CLIENT_PWA_WEBGL  = 2
};

// Capability bitflags (IPD2Hello.caps)
#define IPD2_CAP_H264          (1 << 0)
#define IPD2_CAP_LZ4_BGRA      (1 << 1)
#define IPD2_CAP_LZ4_RGB565    (1 << 2)
#define IPD2_CAP_JPEG_TILE     (1 << 3)

// Display modes
enum IPD2Mode {
    IPD2_MODE_IDLE   = 0,
    IPD2_MODE_SECOND = 1,
    IPD2_MODE_MIRROR = 2
};

// Quality / Resolution presets
enum IPD2Preset {
    IPD2_PRESET_RETINA    = 0, // 1024x768 @ 2x HiDPI = 2048x1536 exact 1:1 iPad 4 Retina
    IPD2_PRESET_WORKSPACE = 1, // 1280x960 @ 2x HiDPI captured at 2048x1536 crisp supersampled
    IPD2_PRESET_SMOOTH    = 2  // 1024x768 1x for ultra-low bandwidth Wi-Fi
};

// Transport type
enum IPD2Transport {
    IPD2_TRANSPORT_USB  = 1,
    IPD2_TRANSPORT_WIFI = 2
};

// Host OS kind
enum IPD2OSKind {
    IPD2_OS_MACOS   = 1,
    IPD2_OS_WINDOWS = 2,
    IPD2_OS_LINUX   = 3
};

// Virtual display position relative to main display
enum IPD2Position {
    IPD2_POS_RIGHT  = 0,
    IPD2_POS_LEFT   = 1,
    IPD2_POS_TOP    = 2,
    IPD2_POS_BOTTOM = 3
};

// Tile batch flags (IPD2Header.flags)
#define IPD2_TILE_FLAG_FULL_SYNC    (1 << 0) // Switch renderer back to crisp Retina tile texture
#define IPD2_TILE_FLAG_HALF_RES     (1 << 1) // Half-res motion frame (upscale cleanly on GPU)
#define IPD2_TILE_FLAG_END_OF_FRAME (1 << 2) // Final sub-batch of frame (client sends FRAME_ACK)

// H264 frame flags (IPD2Header.flags)
#define IPD2_H264_FLAG_KEYFRAME   (1 << 0)

// Tile pixel encodings
enum IPD2TileEncoding {
    IPD2_ENC_LZ4_BGRA   = 1, // Lossless 32-bit BGRA compressed with LZ4
    IPD2_ENC_JPEG       = 2, // JPEG tile
    IPD2_ENC_RAW_BGRA   = 3, // Uncompressed 32-bit BGRA (if LZ4 didn't shrink)
    IPD2_ENC_LZ4_RGB565 = 4, // 16-bit RGB565 compressed with LZ4 (fast motion)
    IPD2_ENC_RAW_RGB565 = 5  // Uncompressed 16-bit RGB565
};

// Input event types
enum IPD2InputType {
    IPD2_INPUT_MOVE         = 1,
    IPD2_INPUT_LEFT_DOWN    = 2,
    IPD2_INPUT_LEFT_UP      = 3,
    IPD2_INPUT_RIGHT_DOWN   = 4,
    IPD2_INPUT_RIGHT_UP     = 5,
    IPD2_INPUT_SCROLL       = 6, // x = dx, y = dy (pixels)
    IPD2_INPUT_KEY_CHAR     = 7, // keyData = UTF-32 char or special key
    IPD2_INPUT_DOUBLE_CLICK = 8,
    IPD2_INPUT_LEFT_DRAG    = 9,
    IPD2_INPUT_KEY_SPECIAL  = 10 // keyData = 1:Return, 2:Backspace, 3:Tab, 4:Escape, 5-8:Arrows
};

// Control commands
enum IPD2ControlCmd {
    IPD2_CTRL_SET_MODE     = 1, // arg1 = IPD2Mode
    IPD2_CTRL_SET_PRESET   = 2, // arg1 = IPD2Preset
    IPD2_CTRL_SET_POSITION = 3, // arg1 = IPD2Position
    IPD2_CTRL_REQUEST_SYNC = 4  // Force immediate full lossless Retina frame
};

// All multi-byte fields are Little-Endian.

typedef struct __attribute__((packed)) {
    uint8_t  magic[4];    // "IPD2"
    uint8_t  type;        // IPD2MessageType
    uint8_t  flags;       // Message-specific flags
    uint16_t extra;       // e.g. tileCount for TILE_BATCH
    uint32_t seq;         // Monotonic frame/packet sequence
    uint32_t payloadLen;  // Payload length in bytes
} IPD2Header;             // 16 bytes

typedef struct __attribute__((packed)) {
    uint8_t  clientKind;  // IPD2ClientKind
    uint8_t  caps;        // IPD2_CAP_* bitmask
    uint16_t screenW;     // Physical pixel width (e.g. 2048)
    uint16_t screenH;     // Physical pixel height (e.g. 1536)
    uint16_t maxH264W;    // Max HW H264 decode width (e.g. 1920)
    uint16_t maxH264H;    // Max HW H264 decode height (e.g. 1080)
    uint8_t  scale;       // Display scale factor (e.g. 2)
    uint8_t  pad[9];
} IPD2Hello;              // 20 bytes

typedef struct __attribute__((packed)) {
    uint8_t  mode;              // IPD2Mode
    uint8_t  preset;            // IPD2Preset
    uint8_t  transport;         // IPD2Transport
    uint8_t  osKind;            // IPD2OSKind
    uint16_t fbWidth;           // Retina tile framebuffer width
    uint16_t fbHeight;          // Retina tile framebuffer height
    uint16_t logicalWidth;      // Logical display width (points)
    uint16_t logicalHeight;     // Logical display height (points)
    uint16_t videoWidth;        // H.264 stream width (<= 1920)
    uint16_t videoHeight;       // H.264 stream height (<= 1080)
    uint16_t fps;               // Current measured FPS
    uint16_t rttTenthMs;        // RTT in 0.1ms units
    uint8_t  position;          // IPD2Position
    uint8_t  hasVirtualDisplay; // 1 if virtual display available
    char     hostName[42];      // UTF-8 null-terminated host name
} IPD2DisplayInfo;              // 64 bytes

typedef struct __attribute__((packed)) {
    uint16_t videoW;
    uint16_t videoH;
    uint16_t spsLen;
    uint16_t ppsLen;
    // Followed by sps[spsLen] and pps[ppsLen]
} IPD2H264ConfigHeader;         // 8 bytes

typedef struct __attribute__((packed)) {
    uint64_t ptsUs;
    // Followed by AVCC length-prefixed NAL units
} IPD2H264FrameHeader;          // 8 bytes

typedef struct __attribute__((packed)) {
    uint16_t frameW;
    uint16_t frameH;
    // Followed by header.extra IPD2TileHeader + tile bytes
} IPD2TileBatchHeader;          // 4 bytes

typedef struct __attribute__((packed)) {
    uint16_t x;
    uint16_t y;
    uint16_t w;
    uint16_t h;
    uint8_t  encoding;          // IPD2TileEncoding
    uint8_t  pad;
    uint32_t dataLen;
    // Followed by dataLen bytes
} IPD2TileHeader;               // 14 bytes

typedef struct __attribute__((packed)) {
    float    normX;             // 0.0 .. 1.0
    float    normY;             // 0.0 .. 1.0
    uint8_t  visible;           // 0 or 1
    uint8_t  cursorType;        // 0=arrow, 1=ibeam, 2=hand, 3=crosshair
    uint16_t pad1;
    uint32_t pad2;
} IPD2Cursor;                   // 16 bytes

typedef struct __attribute__((packed)) {
    uint8_t  eventType;         // IPD2InputType
    uint8_t  modifiers;         // bit0=shift, bit1=ctrl, bit2=alt, bit3=cmd
    uint16_t clickCount;
    float    x;                 // Normalized 0..1 (or scroll dx)
    float    y;                 // Normalized 0..1 (or scroll dy)
    uint32_t keyData;           // UTF-32 codepoint or special key code
} IPD2Input;                    // 20 bytes

typedef struct __attribute__((packed)) {
    uint8_t  cmd;               // IPD2ControlCmd
    uint8_t  arg1;
    uint16_t arg2;
    uint32_t arg3;
} IPD2Control;                  // 8 bytes

typedef struct __attribute__((packed)) {
    uint64_t timestampUs;
} IPD2Ping;                     // 8 bytes

typedef struct __attribute__((packed)) {
    uint32_t ackSeq;
} IPD2FrameAck;                 // 4 bytes

static inline void ipd2_init_header(IPD2Header *h, uint8_t type, uint8_t flags,
                                    uint16_t extra, uint32_t seq, uint32_t payloadLen) {
    h->magic[0] = IPD2_MAGIC_0;
    h->magic[1] = IPD2_MAGIC_1;
    h->magic[2] = IPD2_MAGIC_2;
    h->magic[3] = IPD2_MAGIC_3;
    h->type = type;
    h->flags = flags;
    h->extra = extra;
    h->seq = seq;
    h->payloadLen = payloadLen;
}

#endif // IPD2_PROTOCOL_H
