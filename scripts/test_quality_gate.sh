#!/bin/bash
set -e

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$ROOT_DIR"
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

echo "================================================================="
echo "  🛡️  iPad Display Pro v2.0 — 6-Stage Automated Quality Gate"
echo "================================================================="

# STAGE 1: Static & Multi-Platform Build Validation
echo "[Stage 1/6] Validando ES5, CSS iOS 10, Go tests e binários..."
node --check public/app.js
node -e '
const fs = require("fs");
const js = fs.readFileSync("public/app.js", "utf8");
for (const r of [/\blet\s+/, /\bconst\s+/, /=>/, /`/, /\bclass\s+/]) {
  if (r.test(js)) { console.error("ES6 proibido em app.js:", r); process.exit(1); }
}
const css = fs.readFileSync("public/styles.css", "utf8");
if (/(^|[;\s])gap\s*:/m.test(css)) { console.error("CSS flexbox gap proibido no iOS 10!"); process.exit(1); }
'
(cd host/windows && go test .)
rm -rf /tmp/qg_ipa && mkdir -p /tmp/qg_ipa
unzip -q dist/iPadDisplay.ipa -d /tmp/qg_ipa
lipo -info /tmp/qg_ipa/Payload/iPadDisplay.app/iPadDisplay | grep -q "armv7s arm64"
plutil -lint /tmp/qg_ipa/Payload/iPadDisplay.app/Info.plist >/dev/null
plutil -lint "dist/iPad Display.app/Contents/Info.plist" >/dev/null
rm -rf /tmp/qg_ipa
echo "  ✓ Stage 1 PASSED"

# STAGE 2: Hardware H.264 Moving-Window Round-Trip Quality Gate
echo "[Stage 2/6] Testando H.264 HW Encode -> Decode (30 frames janela em movimento + PSNR frame-exato)..."
clang -O2 -fobjc-arc -framework Foundation -framework CoreGraphics -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework ImageIO -framework UniformTypeIdentifiers \
  scripts/test_h264_roundtrip.m -o /tmp/test_h264_roundtrip
/tmp/test_h264_roundtrip
rm -f /tmp/test_h264_roundtrip
echo "  ✓ Stage 2 PASSED"

# Compile live secondary-screen motion animator for Stage 4
clang -O2 -fobjc-arc -framework Cocoa scripts/test_motion_window.m -o /tmp/test_motion_window

# STAGE 3-6: Live Daemon E2E (Second 2048x1536 Non-Black + Live Motion H.264/Backpressure/Sharpen + Mirror 16:10 + WebSocket PWA)
echo "[Stage 3-6/6] Rodando E2E ao vivo (Second Retina + Drag 60 FPS + Backpressure + Sharpen + Mirror + WebSocket)..."
TEST_PORT_HTTP=18080
TEST_PORT_TCP=13456
./bin/ipad-display-macos --headless --http-port $TEST_PORT_HTTP --tcp-port $TEST_PORT_TCP > /tmp/qg_host.log 2>&1 &
HOST_PID=$!
trap 'kill -INT $HOST_PID 2>/dev/null || true; wait $HOST_PID 2>/dev/null || true; rm -f /tmp/test_motion_window' EXIT
sleep 1.0

python3 - << 'PYEOF'
import socket, struct, time, ctypes, base64, os, urllib.request, subprocess, select

lib = ctypes.CDLL("/usr/local/lib/liblz4.dylib")
lib.LZ4_decompress_safe.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
lib.LZ4_decompress_safe.restype = ctypes.c_int

def pack_hdr(t, flags=0, extra=0, seq=0, payload=b""):
    return struct.pack("<4sBBHII", b"IPD2", t, flags, extra, seq, len(payload)) + payload

def read_exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c: raise EOFError("closed")
        buf.extend(c)
    return bytes(buf)

# HTTP check
for p in ["/", "/app.js", "/styles.css", "/api/status"]:
    with urllib.request.urlopen(f"http://127.0.0.1:18080{p}", timeout=3) as r:
        assert r.status == 200 and len(r.read()) > 20

# Stage 3: Native TCP SECOND + END_OF_FRAME + Non-Black 2048x1536 Retina
s = socket.create_connection(("127.0.0.1", 13456), timeout=8)
s.sendall(pack_hdr(0x01, payload=struct.pack("<BBHHHHB9s", 1, 3, 2048, 1536, 1280, 960, 2, b"\x00"*9)))
s.sendall(pack_hdr(0x08, payload=struct.pack("<BBHI", 1, 1, 0, 0)))

tiles = non_black = eof_seen = 0
max_batch = 0
t0 = time.time()
while time.time() - t0 < 8.0 and not (tiles >= 192 and eof_seen):
    hdr = read_exact(s, 16)
    magic, mt, fl, ex, sq, pl = struct.unpack("<4sBBHII", hdr)
    assert magic == b"IPD2"
    data = read_exact(s, pl) if pl else b""
    if mt == 5:
        max_batch = max(max_batch, pl)
        if fl & 4: eof_seen += 1
        off = 4
        for _ in range(ex):
            tx, ty, tw, th, enc, pad, dlen = struct.unpack("<HHHHBBI", data[off:off+14])
            off += 14
            td = data[off:off+dlen]; off += dlen
            raw_sz = tw * th * 4
            if enc == 1:
                out = ctypes.create_string_buffer(raw_sz)
                assert lib.LZ4_decompress_safe(td, out, dlen, raw_sz) == raw_sz
                b = out.raw
            else:
                b = td
            if any(b[k] > 5 for k in range(0, min(4096, len(b)), 64)):
                non_black += 1
            tiles += 1
        if fl & 4:
            s.sendall(pack_hdr(0x0B, payload=struct.pack("<I", sq)))
    elif mt == 4:
        s.sendall(pack_hdr(0x0B, payload=struct.pack("<I", sq)))

print(f"  ✓ Stage 3 SECOND Retina: tiles={tiles} non_black={non_black} eof={eof_seen} max_batch={max_batch/1024:.1f}KB")
assert tiles >= 192 and non_black >= 150 and eof_seen >= 1

# Stage 4: Live 60 FPS Continuous Motion + Backpressure + Mid-Motion RTT + Post-Motion Retina Sharpen Recovery!
motion_proc = subprocess.Popen(["/tmp/test_motion_window"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
h264_cfg = None
h264_frames = 0
h264_first_is_idr = None
h264_bytes = 0
sharpen_recovered = False
mid_ping_sent = False
mid_ping_ts = 0.0
mid_rtt_ms = None
motion_stopped_at = None

s.settimeout(0.25)
t_m0 = time.time()
while time.time() - t_m0 < 4.5:
    if motion_proc.poll() is not None and motion_stopped_at is None:
        motion_stopped_at = time.time()
    # Send PING right in the middle of heavy 60 FPS dragging to prove ZERO queue bloat!
    if not mid_ping_sent and h264_frames >= 10:
        mid_ping_sent = True
        mid_ping_ts = time.time()
        s.sendall(pack_hdr(0x09, seq=777, payload=struct.pack("<Q", int(mid_ping_ts * 1_000_000))))
    try:
        hdr = read_exact(s, 16)
    except socket.timeout:
        if sharpen_recovered and mid_rtt_ms is not None and motion_proc.poll() is not None:
            break
        continue
    magic, mt, fl, ex, sq, pl = struct.unpack("<4sBBHII", hdr)
    assert magic == b"IPD2"
    data = read_exact(s, pl) if pl else b""
    if mt == 3: # H264_CONFIG
        vw, vh, spsl, ppsl = struct.unpack("<HHHH", data[:8])
        h264_cfg = (vw, vh, spsl, ppsl)
    elif mt == 4: # H264_FRAME
        if h264_first_is_idr is None:
            h264_first_is_idr = bool(fl & 1)
        h264_frames += 1
        h264_bytes += pl
        # Simulate real A6X 10ms decode + send FRAME_ACK (tests real end-to-end pacing!)
        time.sleep(0.010)
        s.sendall(pack_hdr(0x0B, payload=struct.pack("<I", sq)))
    elif mt == 5: # TILE_BATCH
        if (fl & 1) and (fl & 4) and h264_frames >= 10:
            sharpen_recovered = True
        if fl & 4:
            s.sendall(pack_hdr(0x0B, payload=struct.pack("<I", sq)))
    elif mt == 0x0A and sq == 777:
        mid_rtt_ms = (time.time() - mid_ping_ts) * 1000.0
    if sharpen_recovered and mid_rtt_ms is not None and motion_proc.poll() is not None:
        break

motion_proc.wait(timeout=3)
s.settimeout(8.0)
avg_h264_kb = (h264_bytes / h264_frames / 1024.0) if h264_frames else 0.0
print(f"  ✓ Stage 4 LIVE MOTION: cfg={h264_cfg[:2] if h264_cfg else None} frames={h264_frames} firstIDR={h264_first_is_idr} avg={avg_h264_kb:.1f}KB midRTT={mid_rtt_ms:.2f}ms sharpenRetina={sharpen_recovered}")
assert h264_cfg is not None and h264_cfg[0] == 1280 and h264_cfg[1] == 960
assert h264_frames >= 20 and h264_first_is_idr is True
assert mid_rtt_ms is not None and mid_rtt_ms < 50.0
assert sharpen_recovered is True

# Stage 5: Mirror 16:10 + virtual display destruction
s.sendall(pack_hdr(0x08, payload=struct.pack("<BBHI", 1, 2, 0, 0)))
m_tiles = 0; m_fb = None
t1 = time.time()
while time.time() - t1 < 6.0 and not (m_fb and m_tiles >= 100):
    hdr = read_exact(s, 16)
    magic, mt, fl, ex, sq, pl = struct.unpack("<4sBBHII", hdr)
    data = read_exact(s, pl) if pl else b""
    if mt == 2:
        mode, preset, tr, os_k, fw, fh = struct.unpack("<BBBBHH", data[:8])
        if mode == 2 and fw > 0: m_fb = (fw, fh)
    elif mt == 5 and m_fb:
        m_tiles += ex
        if fl & 4:
            s.sendall(pack_hdr(0x0B, payload=struct.pack("<I", sq)))
    elif mt == 4:
        s.sendall(pack_hdr(0x0B, payload=struct.pack("<I", sq)))
print(f"  ✓ Stage 5 MIRROR 16:10: fb={m_fb} tiles={m_tiles}")
assert m_fb == (2048, 1280) and m_tiles >= 100
s.sendall(pack_hdr(0x08, payload=struct.pack("<BBHI", 1, 0, 0, 0)))
time.sleep(0.4)
s.close()

# Stage 6: Binary WebSocket PWA
ws = socket.create_connection(("127.0.0.1", 18080), timeout=8)
key = base64.b64encode(os.urandom(16)).decode()
ws.sendall(f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:18080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
resp = b""
while b"\r\n\r\n" not in resp: resp += ws.recv(4096)
assert b"101 Switching Protocols" in resp

def send_ws(data):
    mask = os.urandom(4)
    hdr = bytearray([0x82])
    n = len(data)
    if n < 126: hdr.append(0x80 | n)
    else: hdr.append(0x80 | 126); hdr.extend(struct.pack(">H", n))
    hdr.extend(mask)
    ws.sendall(bytes(hdr) + bytes(b ^ mask[i & 3] for i, b in enumerate(data)))

def recv_ws():
    b = read_exact(ws, 2)
    plen = b[1] & 0x7F
    if plen == 126: plen = struct.unpack(">H", read_exact(ws, 2))[0]
    elif plen == 127: plen = struct.unpack(">Q", read_exact(ws, 8))[0]
    return b[0] & 0x0F, read_exact(ws, plen)

send_ws(pack_hdr(0x01, payload=struct.pack("<BBHHHHB9s", 2, 6, 2048, 1536, 0, 0, 2, b"\x00"*9)))
send_ws(pack_hdr(0x08, payload=struct.pack("<BBHI", 1, 1, 0, 0)))
ws_tiles = 0
t2 = time.time()
while time.time() - t2 < 8.0 and ws_tiles < 192:
    op, msg = recv_ws()
    if op == 2 and len(msg) >= 16:
        magic, mt, fl, ex, sq, pl = struct.unpack("<4sBBHII", msg[:16])
        if mt == 5:
            ws_tiles += ex
            if fl & 4: send_ws(pack_hdr(0x0B, payload=struct.pack("<I", sq)))
print(f"  ✓ Stage 6 PWA WebSocket: tiles={ws_tiles}")
assert ws_tiles >= 192
send_ws(pack_hdr(0x08, payload=struct.pack("<BBHI", 1, 0, 0, 0)))
time.sleep(0.4)
ws.close()
PYEOF

echo "================================================================="
echo "  ✅ ALL 6 QUALITY GATE STAGES PASSED!"
echo "================================================================="
