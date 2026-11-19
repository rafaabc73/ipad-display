#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# Recompila automaticamente o motor nativo macOS se não existir ou se algum fonte foi alterado
NEED_BUILD=0
if [ ! -f "bin/ipad-display-macos" ]; then
  NEED_BUILD=1
else
  for f in shared/protocol.h host/macos/*.h host/macos/*.m; do
    if [ "$f" -nt "bin/ipad-display-macos" ]; then
      NEED_BUILD=1
      break
    fi
  done
fi

if [ "$NEED_BUILD" -eq 1 ]; then
  echo "[*] Compilando motor nativo macOS (HiDPI 2048x1536 + VideoToolbox H.264 + usbmuxd)..."
  mkdir -p bin
  clang -O3 -Wall -Wextra -Wno-unused-parameter -fobjc-arc \
    -Ishared -Ishared/lz4 \
    shared/lz4/lz4.c \
    host/macos/virtual_display.m \
    host/macos/input_injector.m \
    host/macos/capture_engine.m \
    host/macos/usbmux_bridge.m \
    host/macos/net_server.m \
    host/macos/main.m \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework VideoToolbox \
    -framework QuartzCore \
    -o bin/ipad-display-macos
  echo "✓ Motor compilado!"
fi

exec ./bin/ipad-display-macos "$@"
