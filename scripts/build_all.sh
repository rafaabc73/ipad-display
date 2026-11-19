#!/bin/bash
set -e

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$ROOT_DIR"

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
mkdir -p bin dist

echo "================================================================="
echo "  🔨 Compilando iPad Display Pro v2.0 (macOS + iOS + Windows)"
echo "================================================================="

# 1. Host nativo macOS
echo "[1/4] Compilando motor nativo macOS (HiDPI + ScreenCaptureKit + VideoToolbox + usbmuxd)..."
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
  -framework IOKit \
  -o bin/ipad-display-macos
echo "✓ bin/ipad-display-macos pronto!"

# 2. Bundle clicável macOS (dist/iPad Display.app)
echo "[2/4] Empacotando aplicativo macOS (dist/iPad Display.app)..."
MAC_APP="dist/iPad Display.app"
rm -rf "$MAC_APP"
mkdir -p "$MAC_APP/Contents/MacOS" "$MAC_APP/Contents/Resources/public"
cp bin/ipad-display-macos "$MAC_APP/Contents/MacOS/iPadDisplay"
cp -R public/* "$MAC_APP/Contents/Resources/public/"

cat > "$MAC_APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>iPadDisplay</string>
    <key>CFBundleIdentifier</key>
    <string>com.rafael.ipaddisplay.host</string>
    <key>CFBundleName</key>
    <string>iPad Display</string>
    <key>CFBundleDisplayName</key>
    <string>iPad Display</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundleVersion</key>
    <string>200</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>O iPad Display captura a tela do Mac para estender ou espelhar no seu iPad em qualidade Retina.</string>
</dict>
</plist>
EOF
codesign --force --deep --sign - "$MAC_APP" 2>/dev/null || true
echo "✓ dist/iPad Display.app pronto!"

# 3. App Nativo Universal iOS (.ipa armv7s + arm64)
echo "[3/4] Compilando App Nativo iOS (.ipa 32-bit armv7s + 64-bit arm64)..."
./ios/build_ipa.sh

# 4. Host Windows 10/11 standalone (.exe)
if command -v go >/dev/null 2>&1; then
  echo "[4/4] Compilando Host Windows standalone (dist/iPadDisplay-Windows.exe)..."
  mkdir -p host/windows/web
  cp -R public/* host/windows/web/
  (cd host/windows && GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -o ../../dist/iPadDisplay-Windows.exe .)
  echo "✓ dist/iPadDisplay-Windows.exe pronto!"
else
  echo "[4/4] Go não encontrado — pulando compilação do executável Windows."
fi

echo ""
echo "================================================================="
echo "  ✅ Todos os artefatos prontos em ./dist/"
echo "================================================================="
ls -lh dist/
