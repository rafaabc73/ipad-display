#!/bin/bash
set -e

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$ROOT_DIR"

SDK_PATH="${IOS_SDK:-/Volumes/RAFAEL HD 1/dev_env/sdks/iPhoneOS10.3.sdk}"
if [ ! -d "$SDK_PATH" ]; then
  echo "[!] iPhoneOS10.3.sdk não encontrado em: $SDK_PATH"
  echo "    Baixando automaticamente da base theos/sdks..."
  mkdir -p "$(dirname "$SDK_PATH")"
  curl -sL "https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS10.3.sdk.tar.xz" -o /tmp/iPhoneOS10.3.sdk.tar.xz
  tar -xf /tmp/iPhoneOS10.3.sdk.tar.xz -C "$(dirname "$SDK_PATH")"
  rm -f /tmp/iPhoneOS10.3.sdk.tar.xz
fi

BUILD_DIR="$ROOT_DIR/.build/ios"
APP_DIR="$BUILD_DIR/Payload/iPadDisplay.app"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR" "$ROOT_DIR/dist"

SOURCES=(
  ios/ios_compat.c
  shared/lz4/lz4.c
  ios/VideoDecoder.m
  ios/GLDisplayView.m
  ios/ConnectionManager.m
  ios/DisplayViewController.m
  ios/HomeViewController.m
  ios/AppDelegate.m
  ios/main.m
)

COMMON_FLAGS=(
  -isysroot "$SDK_PATH"
  -miphoneos-version-min=10.0
  -fobjc-arc
  -fno-exceptions
  -fno-objc-exceptions
  -O3
  -fno-builtin-memcpy -fno-builtin-memmove -fno-builtin-memset -fno-builtin-bzero
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
  -Ishared -Ishared/lz4
  -Wl,-ld_classic
  -framework UIKit
  -framework Foundation
  -framework CFNetwork
  -framework CoreGraphics
  -framework QuartzCore
  -framework OpenGLES
  -framework VideoToolbox
  -framework CoreVideo
  -framework CoreMedia
)

echo "[iOS 1/3] Compilando arquitetura 32-bit armv7s (iPad 4 / iOS 10.3.3)..."
clang -arch armv7s "${COMMON_FLAGS[@]}" "${SOURCES[@]}" -o "$BUILD_DIR/iPadDisplay-armv7s" 2>&1 | grep -v "built for iOS Simulator" || true
if [ ! -f "$BUILD_DIR/iPadDisplay-armv7s" ]; then
  echo "[ERRO] Falha ao compilar armv7s."
  exit 1
fi

echo "[iOS 2/3] Compilando arquitetura 64-bit arm64 (iPads modernos)..."
clang -arch arm64 "${COMMON_FLAGS[@]}" "${SOURCES[@]}" -o "$BUILD_DIR/iPadDisplay-arm64" 2>&1 | grep -v "built for iOS Simulator" || true
if [ ! -f "$BUILD_DIR/iPadDisplay-arm64" ]; then
  echo "[ERRO] Falha ao compilar arm64."
  exit 1
fi

echo "[iOS 3/3] Empacotando binário universal + ícones Retina em dist/iPadDisplay.ipa..."
lipo -create "$BUILD_DIR/iPadDisplay-armv7s" "$BUILD_DIR/iPadDisplay-arm64" -output "$APP_DIR/iPadDisplay"
chmod +x "$APP_DIR/iPadDisplay"
cp ios/Info.plist "$APP_DIR/Info.plist"
printf "APPL????" > "$APP_DIR/PkgInfo"

# Gerar ícones oficiais iPad (76, 152, 167, 120) com sips
if [ -f "public/icon-512.png" ]; then
  sips -z 76  76  public/icon-512.png --out "$APP_DIR/AppIcon76x76~ipad.png" >/dev/null
  sips -z 152 152 public/icon-512.png --out "$APP_DIR/AppIcon76x76@2x~ipad.png" >/dev/null
  sips -z 167 167 public/icon-512.png --out "$APP_DIR/AppIcon83.5x83.5@2x~ipad.png" >/dev/null
  sips -z 120 120 public/icon-512.png --out "$APP_DIR/AppIcon60x60@2x.png" >/dev/null
fi

(cd "$BUILD_DIR" && zip -qr "$ROOT_DIR/dist/iPadDisplay.ipa" Payload)
rm -rf "$BUILD_DIR"

echo "✓ App Nativo gerado: dist/iPadDisplay.ipa"
ls -lh "$ROOT_DIR/dist/iPadDisplay.ipa"
