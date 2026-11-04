#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "=========================================================="
echo "    🍏 iPad Display Server (PWA Segunda Tela & Espelho)  "
echo "=========================================================="

# Gerar certificados SSL/TLS autoassinados para HTTPS se não existirem
if [ ! -f "key.pem" ] || [ ! -f "cert.pem" ]; then
    echo "[*] Gerando certificados SSL/TLS para suporte a HTTPS no Safari..."
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=iPadDisplay" 2>/dev/null || true
fi

# Compilar motor nativo se não existir
if [ ! -f "bin/ipad-display-core" ]; then
    echo "[1/2] Compilando motor nativo macOS (ScreenCaptureKit)..."
    mkdir -p bin
    clang -O3 -fobjc-arc \
      -framework CoreGraphics \
      -framework ScreenCaptureKit \
      -framework Foundation \
      -framework CoreMedia \
      -framework CoreVideo \
      -framework VideoToolbox \
      -framework ImageIO \
      -framework QuartzCore \
      -framework UniformTypeIdentifiers \
      -o "bin/ipad-display-core" "src/core.m"
    echo "✓ Motor compilado com sucesso!"
fi

echo "[2/2] Iniciando servidor Node.js..."
node src/server.js

