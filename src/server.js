const net = require('net');
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const PORT = process.env.PORT || 8080;
const BIN_PATH = path.join(__dirname, '..', 'bin', 'ipad-display-core');
const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const KEY_PATH = path.join(__dirname, '..', 'key.pem');
const CERT_PATH = path.join(__dirname, '..', 'cert.pem');

// Estado global do servidor
let currentMode = 'second'; // Padrão: Segunda Tela
let currentSettings = { quality: 0.55, fps: 30, width: 1280, height: 960 };
let coreProcess = null;
let mjpegClients = new Set();
let lastFrame = null;
let lastFrameMode = null;
let frameCount = 0;
let lastFpsCalculation = Date.now();
let currentFps = 0;

// Atualiza o cálculo de FPS a cada segundo para refletir o status real
setInterval(() => {
  const now = Date.now();
  const elapsed = now - lastFpsCalculation;
  if (elapsed >= 1000) {
    currentFps = Math.round((frameCount * 1000) / elapsed);
    frameCount = 0;
    lastFpsCalculation = now;
  }
}, 1000);

// Inicializa o processo nativo Objective-C
function startCoreProcess() {
  if (coreProcess) return;

  console.log('[Servidor] Iniciando motor nativo de captura e tela virtual...');
  coreProcess = spawn(BIN_PATH, ['--mode', currentMode, '--quality', '0.55', '--fps', '30'], {
    stdio: ['pipe', 'pipe', 'inherit']
  });

  let buffer = Buffer.alloc(0);
  const MAGIC = Buffer.from('IPAD');

  coreProcess.stdout.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);

    while (buffer.length >= 8) {
      if (!buffer.subarray(0, 4).equals(MAGIC)) {
        const magicIndex = buffer.indexOf(MAGIC);
        if (magicIndex === -1) {
          buffer = Buffer.alloc(0);
          break;
        } else {
          buffer = buffer.subarray(magicIndex);
          if (buffer.length < 8) break;
        }
      }

      const frameLen = buffer.readUInt32BE(4);
      const totalLen = 8 + frameLen;

      if (buffer.length < totalLen) {
        break;
      }

      const frameData = buffer.subarray(8, totalLen);
      buffer = buffer.subarray(totalLen);

      lastFrame = frameData;
      lastFrameMode = currentMode;
      frameCount++;

      const now = Date.now();
      if (now - lastFpsCalculation >= 1000) {
        currentFps = Math.round((frameCount * 1000) / (now - lastFpsCalculation));
        frameCount = 0;
        lastFpsCalculation = now;
      }

      broadcastMjpegFrame(frameData);
    }
  });

  coreProcess.on('exit', (code) => {
    console.log(`[Servidor] Processo nativo encerrado (código ${code})`);
    coreProcess = null;
  });

  coreProcess.on('error', (err) => {
    console.error('[Servidor] Erro ao iniciar processo nativo:', err.message);
    coreProcess = null;
  });
}

function sendCommand(cmd) {
  if (coreProcess && coreProcess.stdin && !coreProcess.stdin.destroyed) {
    coreProcess.stdin.write(cmd + '\n');
  }
}

// Transmissão MJPEG robusta: Zero Delay, sem acúmulo de fila e NUNCA congela
function broadcastMjpegFrame(jpegBuffer) {
  if (mjpegClients.size === 0) return;

  const header = Buffer.from(
    `--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpegBuffer.length}\r\n\r\n`
  );
  const footer = Buffer.from('\r\n');
  const fullPacket = Buffer.concat([header, jpegBuffer, footer]);

  for (const client of mjpegClients) {
    const res = client.res;
    if (!res || !res.socket || res.socket.destroyed || !res.socket.writable) {
      mjpegClients.delete(client);
      continue;
    }

    // CONTROLE RIGOROSO DE BACKPRESSURE (ZERO DELAY):
    // Se o cliente ainda estiver transmitindo o frame anterior, descarta o frame intermediário
    // no servidor Mac antes que ele chegue na rede ou no buffer do iPad.
    if (client.isWriting) {
      continue;
    }

    client.isWriting = true;
    try {
      res.write(fullPacket, () => {
        client.isWriting = false;
      });
    } catch (err) {
      client.isWriting = false;
      mjpegClients.delete(client);
    }
  }
}

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon'
};

// Manipulador comum de requisições HTTP e HTTPS
function handleRequest(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  const urlObj = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = urlObj.pathname;
  const protocol = req.socket.encrypted ? 'HTTPS' : 'HTTP';

  // Endpoint: Stream MJPEG Contínuo Nativo de Hardware
  if (pathname === '/stream') {
    const clientIp = req.socket.remoteAddress;

    // Fecha streams anteriores do mesmo IP para economizar banda e CPU
    for (const client of mjpegClients) {
      if (client.ip === clientIp) {
        mjpegClients.delete(client);
        try {
          client.res.end();
          client.res.destroy();
        } catch (e) {}
      }
    }

    const requestedMode = urlObj.searchParams.get('mode');
    if (requestedMode && (requestedMode === 'mirror' || requestedMode === 'second') && requestedMode !== currentMode) {
      currentMode = requestedMode;
      lastFrame = null;
      lastFrameMode = null;
      sendCommand(`MODE ${currentMode}`);
      console.log(`[Servidor] Modo alterado para: ${currentMode}`);
    }

    if (req.socket) {
      req.socket.setNoDelay(true); // Desativa algoritmo de Nagle (Zero delay no envio de pacotes)
      req.socket.setKeepAlive(true, 1000);
    }

    res.writeHead(200, {
      'Content-Type': 'multipart/x-mixed-replace; boundary=--frame',
      'Cache-Control': 'no-cache, no-store, must-revalidate, max-age=0',
      'Connection': 'keep-alive',
      'Pragma': 'no-cache',
      'Expires': '0'
    });

    const clientObj = {
      res: res,
      ip: clientIp,
      isWriting: false
    };

    mjpegClients.add(clientObj);
    console.log(`[Servidor] Stream ativo com ${clientIp} (Total de clientes: ${mjpegClients.size})`);

    // Envia o último frame capturado de imediato SOMENTE se for do mesmo modo
    if (lastFrame && lastFrameMode === currentMode) {
      const initHeader = Buffer.from(`--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${lastFrame.length}\r\n\r\n`);
      res.write(Buffer.concat([initHeader, lastFrame, Buffer.from('\r\n')]));
    }

    req.on('close', () => {
      mjpegClients.delete(clientObj);
      console.log(`[Servidor] Stream encerrado com ${clientIp} (Restantes: ${mjpegClients.size})`);
    });
    return;
  }

  // Endpoint: Quadro Único Ultra-Low-Latency (Zero Delay / Sem Fila)
  if (pathname === '/frame.jpg' || pathname === '/frame') {
    if (!lastFrame || lastFrameMode !== currentMode) {
      res.writeHead(503, { 'Retry-After': '0' });
      res.end();
      return;
    }
    res.writeHead(200, {
      'Content-Type': 'image/jpeg',
      'Content-Length': lastFrame.length,
      'Cache-Control': 'no-cache, no-store, must-revalidate, max-age=0',
      'Pragma': 'no-cache',
      'Expires': '0'
    });
    res.end(lastFrame);
    return;
  }

  // Endpoint: Status
  if (pathname === '/api/status' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      mode: currentMode,
      fps: currentFps,
      clients: mjpegClients.size,
      clientIps: Array.from(mjpegClients).map(c => c.ip)
    }));
    return;
  }

  // Endpoint: Ajustar Configurações
  if (pathname === '/api/settings' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        if (data.quality && data.quality !== currentSettings.quality) {
          currentSettings.quality = data.quality;
          sendCommand(`QUALITY ${data.quality}`);
        }
        if (data.fps && data.fps !== currentSettings.fps) {
          currentSettings.fps = data.fps;
          sendCommand(`FPS ${data.fps}`);
        }
        if (data.width && data.height && (data.width !== currentSettings.width || data.height !== currentSettings.height)) {
          currentSettings.width = data.width;
          currentSettings.height = data.height;
          sendCommand(`RES ${data.width} ${data.height}`);
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }

  // Endpoint: Alternar Modo
  if (pathname === '/api/mode' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const newMode = data.mode;
        if (newMode === 'mirror' || newMode === 'second') {
          if (newMode !== currentMode) {
            currentMode = newMode;
            lastFrame = null;
            lastFrameMode = null;
            sendCommand(`MODE ${currentMode}`);
            console.log(`[Servidor] Modo alterado para: ${currentMode}`);
          }
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: true, mode: currentMode }));
        } else {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Modo inválido. Use "mirror" ou "second"' }));
        }
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }

  // Endpoint: Toque na tela (Clique remoto)
  if (pathname === '/api/click' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const x = parseFloat(data.x);
        const y = parseFloat(data.y);
        if (!isNaN(x) && !isNaN(y)) {
          sendCommand(`CLICK ${x} ${y}`);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: true }));
        } else {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Coordenadas inválidas' }));
        }
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }

  // Arquivos estáticos
  let filePath = path.join(PUBLIC_DIR, pathname === '/' ? 'index.html' : pathname);

  fs.stat(filePath, (err, stats) => {
    if (err || !stats.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('404 Arquivo Não Encontrado');
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';

    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Length': stats.size,
      'Cache-Control': 'no-cache, no-store, must-revalidate'
    });

    fs.createReadStream(filePath).pipe(res);
  });
}

// Servidores internos HTTP e HTTPS
const httpServer = http.createServer(handleRequest);

let httpsServer = null;
if (fs.existsSync(KEY_PATH) && fs.existsSync(CERT_PATH)) {
  try {
    httpsServer = https.createServer({
      key: fs.readFileSync(KEY_PATH),
      cert: fs.readFileSync(CERT_PATH),
      minVersion: 'TLSv1.2'
    }, handleRequest);
    console.log('[Servidor] Suporte a HTTPS ativado com certificado TLS 1.2');
  } catch (err) {
    console.error('[Servidor] Erro ao carregar certificados SSL:', err.message);
  }
}

// Servidor multiplexador inteligente: aceita HTTP e HTTPS na MESMA porta!
function createMultiplexServer() {
  return net.createServer((socket) => {
    socket.once('data', (buffer) => {
      socket.pause();
      socket.unshift(buffer);

      if (buffer[0] === 22 && httpsServer) {
        httpsServer.emit('connection', socket);
      } else {
        httpServer.emit('connection', socket);
      }

      process.nextTick(() => socket.resume());
    });

    socket.on('error', (err) => {});
  });
}

const multiplexServer8080 = createMultiplexServer();
const multiplexServer3000 = createMultiplexServer();

// Detecção inteligente de endereços de rede
function getNetworkAddresses() {
  const interfaces = os.networkInterfaces();
  const results = {
    usb: [],
    wifi: []
  };

  for (const [name, addrs] of Object.entries(interfaces)) {
    for (const addr of addrs) {
      if (addr.family === 'IPv4' && !addr.internal) {
        if (addr.address.startsWith('172.20.10.') || addr.address.startsWith('192.168.2.') || name === 'bridge100' || name === 'en5') {
          results.usb.push({ name, ip: addr.address });
        } else {
          results.wifi.push({ name, ip: addr.address });
        }
      }
    }
  }

  return results;
}

// Iniciar servidores nas portas 8080 e 3000
multiplexServer8080.listen(PORT, () => {
  multiplexServer3000.listen(3000, () => {});
  startCoreProcess();

  try {
    const dnsSd = spawn('dns-sd', ['-R', 'iPad Display', '_http._tcp', 'local', String(PORT)], {
      stdio: 'ignore'
    });
    dnsSd.unref();
  } catch (e) {}

  const addrs = getNetworkAddresses();
  console.log('\n=============================================================');
  console.log('   🚀 iPad Display Server (Alta Definição Retina & Zero Delay)!');
  console.log('=============================================================');
  console.log(`Porta: ${PORT} (Aceita HTTP e HTTPS)\n`);

  console.log('⚡ Conexão por Cabo USB (0.6ms de latência):');
  if (addrs.usb.length > 0) {
    addrs.usb.forEach(item => {
      console.log(`   👉 http://${item.ip}:${PORT}`);
      console.log(`   👉 https://${item.ip}:${PORT}`);
    });
  } else {
    console.log(`   👉 http://192.168.2.1:${PORT}`);
    console.log(`   👉 https://192.168.2.1:${PORT}`);
  }

  console.log('\n📶 Conexão por Wi-Fi:');
  console.log(`   👉 http://MacBook-Air-de-Rafael.local:${PORT}`);
  addrs.wifi.forEach(item => {
    console.log(`   👉 http://${item.ip}:${PORT}`);
  });

  console.log('=============================================================\n');
});

process.on('SIGINT', () => {
  console.log('\n[Servidor] Encerrando servidor e liberando tela virtual...');
  if (coreProcess) {
    sendCommand('QUIT');
    setTimeout(() => {
      process.exit(0);
    }, 500);
  } else {
    process.exit(0);
  }
});
