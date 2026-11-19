/* iPad Display Pro v2.0 — Cliente WebGL Retina + LZ4 Lossless (ES5 estrito para iOS 10.3.3+) */
(function () {
  'use strict';

  // ---- Protocolo IPD2 ----
  var MSG_HELLO        = 0x01;
  var MSG_DISPLAY_INFO = 0x02;
  var MSG_TILE_BATCH   = 0x05;
  var MSG_CURSOR       = 0x06;
  var MSG_INPUT        = 0x07;
  var MSG_CONTROL      = 0x08;
  var MSG_PING         = 0x09;
  var MSG_PONG         = 0x0A;
  var MSG_FRAME_ACK    = 0x0B;

  var MODE_IDLE   = 0;
  var MODE_SECOND = 1;
  var MODE_MIRROR = 2;

  var ENC_LZ4_BGRA   = 1;
  var ENC_RAW_BGRA   = 3;
  var ENC_LZ4_RGB565 = 4;
  var ENC_RAW_RGB565 = 5;

  var TILE_FLAG_FULL_SYNC = 1;
  var TILE_FLAG_HALF_RES  = 2;

  var INPUT_MOVE         = 1;
  var INPUT_LEFT_DOWN    = 2;
  var INPUT_LEFT_UP      = 3;
  var INPUT_RIGHT_DOWN   = 4;
  var INPUT_RIGHT_UP     = 5;
  var INPUT_SCROLL       = 6;
  var INPUT_KEY_CHAR     = 7;
  var INPUT_DOUBLE_CLICK = 8;
  var INPUT_LEFT_DRAG    = 9;
  var INPUT_KEY_SPECIAL  = 10;

  var CTRL_SET_MODE     = 1;
  var CTRL_SET_PRESET   = 2;
  var CTRL_SET_POSITION = 3;
  var CTRL_REQUEST_SYNC = 4;

  // ---- DOM ----
  var menuView      = document.getElementById('menuView');
  var displayView   = document.getElementById('displayView');
  var hostSubtitle  = document.getElementById('hostSubtitle');
  var connPill      = document.getElementById('connPill');
  var connLabel     = document.getElementById('connLabel');
  var cardSecond    = document.getElementById('cardSecond');
  var cardMirror    = document.getElementById('cardMirror');
  var glCanvas      = document.getElementById('glCanvas');
  var remoteCursor  = document.getElementById('remoteCursor');
  var streamLoader  = document.getElementById('streamLoader');
  var loaderText    = document.getElementById('loaderText');
  var toolbarHandle = document.getElementById('toolbarHandle');
  var floatingBar   = document.getElementById('floatingBar');
  var btnBack       = document.getElementById('btnBack');
  var btnSwitchMode = document.getElementById('btnSwitchMode');
  var hudStats      = document.getElementById('hudStats');
  var btnPreset     = document.getElementById('btnPreset');
  var btnFit        = document.getElementById('btnFit');
  var btnTouch      = document.getElementById('btnTouch');
  var btnKeyboard   = document.getElementById('btnKeyboard');
  var btnHideBar    = document.getElementById('btnHideBar');
  var kbInput       = document.getElementById('hiddenKeyboardInput');

  // ---- Estado ----
  var ws = null;
  var reconnectTimer = null;
  var autoHideTimer = null;
  var currentMode = MODE_IDLE;
  var currentPreset = 0;
  var currentPos = 0;
  var fillScreen = false;
  var touchEnabled = true;
  var hasFirstFrame = false;
  var frameCounter = 0;
  var measuredFps = 0;
  var lastFpsTs = Date.now();
  var serverRttMs = 0;
  var hostName = 'Computador';

  var presetNames = ['Retina 1:1', 'Mais Espaço', 'Wi-Fi Rápido'];

  // ---- Buffers pré-alocados (ZERO Garbage Collection!) ----
  var tileDecodeBuf   = new Uint8Array(256 * 256 * 4);
  var motionRawBuf    = new ArrayBuffer(1280 * 960 * 2);
  var motionU8        = new Uint8Array(motionRawBuf);
  var motionU16       = new Uint16Array(motionRawBuf);

  // ---- Descompressor LZ4 Block Ultra-Rápido em ES5 (Zero Alocações) ----
  function lz4Decompress(src, srcOffset, srcLen, dst, dstMaxLen) {
    var ip = srcOffset;
    var ipEnd = srcOffset + srcLen;
    var op = 0;

    while (ip < ipEnd) {
      var token = src[ip++];
      var literalLen = token >>> 4;
      if (literalLen === 15) {
        var s;
        do {
          if (ip >= ipEnd) return -1;
          s = src[ip++];
          literalLen += s;
        } while (s === 255);
      }

      if (op + literalLen > dstMaxLen || ip + literalLen > ipEnd) return -1;
      for (var i = 0; i < literalLen; i++) {
        dst[op++] = src[ip++];
      }

      if (ip >= ipEnd) break;

      var offset = src[ip++] | (src[ip++] << 8);
      if (offset === 0 || offset > op) return -1;

      var matchLen = (token & 15) + 4;
      if ((token & 15) === 15) {
        var m;
        do {
          if (ip >= ipEnd) return -1;
          m = src[ip++];
          matchLen += m;
        } while (m === 255);
      }

      if (op + matchLen > dstMaxLen) return -1;
      var ref = op - offset;
      for (var j = 0; j < matchLen; j++) {
        dst[op++] = dst[ref++];
      }
    }
    return op;
  }

  // ---- Renderizador WebGL 1.0 Hardware (PowerVR SGX554MP4 / Metal / ANGLE) ----
  var gl = null;
  var glProgram = null;
  var retinaTex = null;
  var motionTex = null;
  var retinaW = 0, retinaH = 0;
  var motionW = 0, motionH = 0;
  var activeIsMotion = false;
  var locScale = null;
  var locSwapRB = null;
  var needsDraw = false;
  var renderViewport = { x: 0, y: 0, w: 1, h: 1 };

  function initWebGL() {
    var opts = { alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false, powerPreference: 'high-performance' };
    gl = glCanvas.getContext('webgl', opts) || glCanvas.getContext('experimental-webgl', opts);
    if (!gl) return false;

    var vsSrc =
      'attribute vec2 aPos;' +
      'attribute vec2 aTex;' +
      'uniform vec2 uScale;' +
      'varying vec2 vTex;' +
      'void main() {' +
      '  vTex = aTex;' +
      '  gl_Position = vec4(aPos * uScale, 0.0, 1.0);' +
      '}';

    var fsSrc =
      'precision mediump float;' +
      'varying vec2 vTex;' +
      'uniform sampler2D uTex;' +
      'uniform float uSwapRB;' +
      'void main() {' +
      '  vec4 c = texture2D(uTex, vTex);' +
      '  if (uSwapRB > 0.5) {' +
      '    gl_FragColor = vec4(c.b, c.g, c.r, 1.0);' +
      '  } else {' +
      '    gl_FragColor = vec4(c.r, c.g, c.b, 1.0);' +
      '  }' +
      '}';

    function compile(type, src) {
      var sh = gl.createShader(type);
      gl.shaderSource(sh, src);
      gl.compileShader(sh);
      return sh;
    }

    glProgram = gl.createProgram();
    gl.attachShader(glProgram, compile(gl.VERTEX_SHADER, vsSrc));
    gl.attachShader(glProgram, compile(gl.FRAGMENT_SHADER, fsSrc));
    gl.linkProgram(glProgram);
    gl.useProgram(glProgram);

    var verts = new Float32Array([
      -1, -1,  0, 1,
       1, -1,  1, 1,
      -1,  1,  0, 0,
       1,  1,  1, 0
    ]);
    var vbo = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW);

    var aPos = gl.getAttribLocation(glProgram, 'aPos');
    var aTex = gl.getAttribLocation(glProgram, 'aTex');
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 16, 0);
    gl.enableVertexAttribArray(aTex);
    gl.vertexAttribPointer(aTex, 2, gl.FLOAT, false, 16, 8);

    locScale = gl.getUniformLocation(glProgram, 'uScale');
    locSwapRB = gl.getUniformLocation(glProgram, 'uSwapRB');
    gl.uniform1i(gl.getUniformLocation(glProgram, 'uTex'), 0);

    retinaTex = createNPOTTexture();
    motionTex = createNPOTTexture();
    resizeCanvas();
    return true;
  }

  function createNPOTTexture() {
    var t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    return t;
  }

  function resizeCanvas() {
    var dpr = window.devicePixelRatio || 1;
    var cw = Math.round(window.innerWidth * dpr);
    var ch = Math.round(window.innerHeight * dpr);
    if (glCanvas.width !== cw || glCanvas.height !== ch) {
      glCanvas.width = cw;
      glCanvas.height = ch;
    }
    if (gl) {
      gl.viewport(0, 0, glCanvas.width, glCanvas.height);
    }
    updateAspectLayout();
    needsDraw = true;
  }

  function updateAspectLayout() {
    var srcW = activeIsMotion ? motionW : retinaW;
    var srcH = activeIsMotion ? motionH : retinaH;
    var cssW = window.innerWidth;
    var cssH = window.innerHeight;
    if (!srcW || !srcH || !cssW || !cssH) {
      renderViewport = { x: 0, y: 0, w: cssW, h: cssH };
      return;
    }
    if (fillScreen) {
      renderViewport = { x: 0, y: 0, w: cssW, h: cssH };
      return;
    }
    var srcAspect = srcW / srcH;
    var viewAspect = cssW / cssH;
    var rw, rh, rx, ry;
    if (viewAspect > srcAspect) {
      rh = cssH;
      rw = rh * srcAspect;
      rx = (cssW - rw) * 0.5;
      ry = 0;
    } else {
      rw = cssW;
      rh = rw / srcAspect;
      rx = 0;
      ry = (cssH - rh) * 0.5;
    }
    renderViewport = { x: rx, y: ry, w: rw, h: rh };
  }

  function drawGL() {
    if (!gl || (!retinaW && !motionW)) return;
    var srcW = activeIsMotion ? motionW : retinaW;
    var srcH = activeIsMotion ? motionH : retinaH;
    if (!srcW || !srcH) return;

    updateAspectLayout();
    var sx = fillScreen ? 1.0 : (renderViewport.w / window.innerWidth);
    var sy = fillScreen ? 1.0 : (renderViewport.h / window.innerHeight);

    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(glProgram);
    gl.activeTexture(gl.TEXTURE0);

    if (activeIsMotion && motionW > 0) {
      gl.bindTexture(gl.TEXTURE_2D, motionTex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.uniform1f(locSwapRB, 0.0);
    } else {
      gl.bindTexture(gl.TEXTURE_2D, retinaTex);
      // 1:1 exact pixel match -> GL_NEAREST for maximum Retina crispness!
      var exact = (!fillScreen && retinaW === glCanvas.width && retinaH === glCanvas.height);
      var filt = exact ? gl.NEAREST : gl.LINEAR;
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filt);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filt);
      gl.uniform1f(locSwapRB, 1.0);
    }

    gl.uniform2f(locScale, sx, sy);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  function renderLoop() {
    if (needsDraw && currentMode !== MODE_IDLE) {
      needsDraw = false;
      drawGL();
    }
    window.requestAnimationFrame(renderLoop);
  }

  // ---- Envio de Pacotes IPD2 ----
  function makePacket(type, flags, extra, seq, payloadLen) {
    var ab = new ArrayBuffer(16 + payloadLen);
    var dv = new DataView(ab);
    dv.setUint8(0, 73); // 'I'
    dv.setUint8(1, 80); // 'P'
    dv.setUint8(2, 68); // 'D'
    dv.setUint8(3, 50); // '2'
    dv.setUint8(4, type);
    dv.setUint8(5, flags);
    dv.setUint16(6, extra, true);
    dv.setUint32(8, seq, true);
    dv.setUint32(12, payloadLen, true);
    return { ab: ab, dv: dv };
  }

  function sendPacket(ab) {
    if (ws && ws.readyState === 1) {
      ws.send(ab);
    }
  }

  function sendHello() {
    var dpr = Math.round(window.devicePixelRatio || 2);
    var sw = Math.round(Math.max(window.screen.width, window.screen.height) * dpr);
    var sh = Math.round(Math.min(window.screen.width, window.screen.height) * dpr);
    var p = makePacket(MSG_HELLO, 0, 0, 0, 20);
    p.dv.setUint8(16, 2); // PWA WebGL
    p.dv.setUint8(17, (1 << 1) | (1 << 2)); // LZ4 BGRA + LZ4 RGB565
    p.dv.setUint16(18, sw, true);
    p.dv.setUint16(20, sh, true);
    p.dv.setUint16(22, 0, true);
    p.dv.setUint16(24, 0, true);
    p.dv.setUint8(26, dpr);
    sendPacket(p.ab);
  }

  function sendControl(cmd, arg1) {
    var p = makePacket(MSG_CONTROL, 0, 0, 0, 8);
    p.dv.setUint8(16, cmd);
    p.dv.setUint8(17, arg1 || 0);
    sendPacket(p.ab);
  }

  function sendInput(eventType, x, y, clickCount, keyData, modifiers) {
    var p = makePacket(MSG_INPUT, 0, 0, 0, 20);
    p.dv.setUint8(16, eventType);
    p.dv.setUint8(17, modifiers || 0);
    p.dv.setUint16(18, clickCount || 0, true);
    p.dv.setFloat32(20, x || 0, true);
    p.dv.setFloat32(24, y || 0, true);
    p.dv.setUint32(28, keyData || 0, true);
    sendPacket(p.ab);
  }

  function sendFrameAck(seq) {
    var p = makePacket(MSG_FRAME_ACK, 0, 0, 0, 4);
    p.dv.setUint32(16, seq, true);
    sendPacket(p.ab);
  }

  // ---- Recepção de Pacotes IPD2 ----
  function handleBinaryMessage(ab) {
    if (!ab || ab.byteLength < 16) return;
    var dv = new DataView(ab);
    if (dv.getUint8(0) !== 73 || dv.getUint8(1) !== 80 || dv.getUint8(2) !== 68 || dv.getUint8(3) !== 50) return;

    var type = dv.getUint8(4);
    var flags = dv.getUint8(5);
    var extra = dv.getUint16(6, true);
    var seq = dv.getUint32(8, true);
    var plen = dv.getUint32(12, true);
    if (ab.byteLength < 16 + plen) return;

    if (type === MSG_TILE_BATCH) {
      handleTileBatch(ab, dv, flags, extra, seq);
    } else if (type === MSG_CURSOR) {
      handleCursor(dv);
    } else if (type === MSG_DISPLAY_INFO) {
      handleDisplayInfo(ab, dv);
    } else if (type === MSG_PING) {
      var pong = makePacket(MSG_PONG, 0, 0, seq, 8);
      pong.dv.setUint32(16, dv.getUint32(16, true), true);
      pong.dv.setUint32(20, dv.getUint32(20, true), true);
      sendPacket(pong.ab);
    }
  }

  function handleDisplayInfo(ab, dv) {
    if (ab.byteLength < 16 + 64) return;
    var transport = dv.getUint8(18);
    var osKind = dv.getUint8(19);
    var fbW = dv.getUint16(20, true);
    var fbH = dv.getUint16(22, true);
    var rttTenth = dv.getUint16(30, true);
    serverRttMs = rttTenth / 10.0;

    var u8 = new Uint8Array(ab, 16 + 22, 42);
    var nameChars = '';
    for (var i = 0; i < u8.length && u8[i] !== 0; i++) {
      nameChars += String.fromCharCode(u8[i]);
    }
    if (nameChars) hostName = nameChars;

    var osLabel = (osKind === 2) ? 'Windows' : 'macOS';
    var trLabel = (transport === 1) ? 'Cabo USB' : 'Wi-Fi';
    hostSubtitle.textContent = hostName + ' (' + osLabel + ')';
    connPill.className = 'conn-pill';
    connLabel.textContent = trLabel + ' • ' + serverRttMs.toFixed(1) + ' ms';

    updateHud(fbW, fbH);
  }

  function updateHud(fbW, fbH) {
    var w = fbW || retinaW;
    var h = fbH || retinaH;
    var resStr = (w && h) ? (w + '×' + h) : 'Retina';
    hudStats.textContent = resStr + ' • ' + measuredFps + ' FPS • ' + serverRttMs.toFixed(1) + 'ms';
  }

  function handleCursor(dv) {
    if (currentMode === MODE_IDLE) return;
    var nx = dv.getFloat32(16, true);
    var ny = dv.getFloat32(20, true);
    var vis = dv.getUint8(24);
    if (!vis) {
      remoteCursor.classList.add('hidden');
      return;
    }
    remoteCursor.classList.remove('hidden');
    var px = renderViewport.x + nx * renderViewport.w;
    var py = renderViewport.y + ny * renderViewport.h;
    var tf = 'translate3d(' + px.toFixed(1) + 'px,' + py.toFixed(1) + 'px,0)';
    remoteCursor.style.webkitTransform = tf;
    remoteCursor.style.transform = tf;
  }

  function handleTileBatch(ab, dv, flags, tileCount, seq) {
    if (!gl || currentMode === MODE_IDLE) return;

    var frameW = dv.getUint16(16, true);
    var frameH = dv.getUint16(18, true);
    var isHalfMotion = (flags & TILE_FLAG_HALF_RES) !== 0;
    var srcU8 = new Uint8Array(ab);
    var off = 20;

    if (isHalfMotion) {
      gl.bindTexture(gl.TEXTURE_2D, motionTex);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 2);
      if (frameW !== motionW || frameH !== motionH) {
        motionW = frameW;
        motionH = frameH;
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, motionW, motionH, 0, gl.RGB, gl.UNSIGNED_SHORT_5_6_5, null);
      }

      for (var m = 0; m < tileCount; m++) {
        if (off + 14 > ab.byteLength) break;
        var mx = dv.getUint16(off, true);
        var my = dv.getUint16(off + 2, true);
        var mw = dv.getUint16(off + 4, true);
        var mh = dv.getUint16(off + 6, true);
        var menc = dv.getUint8(off + 8);
        var mlen = dv.getUint32(off + 10, true);
        off += 14;
        if (off + mlen > ab.byteLength) break;

        var expectedBytes = mw * mh * 2;
        if (expectedBytes <= motionRawBuf.byteLength) {
          if (menc === ENC_LZ4_RGB565) {
            var dec = lz4Decompress(srcU8, off, mlen, motionU8, expectedBytes);
            if (dec === expectedBytes) {
              var u16View = new Uint16Array(motionRawBuf, 0, mw * mh);
              gl.texSubImage2D(gl.TEXTURE_2D, 0, mx, my, mw, mh, gl.RGB, gl.UNSIGNED_SHORT_5_6_5, u16View);
            }
          } else if (menc === ENC_RAW_RGB565 && mlen === expectedBytes) {
            motionU8.set(srcU8.subarray(off, off + mlen), 0);
            var rawView = new Uint16Array(motionRawBuf, 0, mw * mh);
            gl.texSubImage2D(gl.TEXTURE_2D, 0, mx, my, mw, mh, gl.RGB, gl.UNSIGNED_SHORT_5_6_5, rawView);
          }
        }
        off += mlen;
      }
      activeIsMotion = true;
      sendFrameAck(seq);
    } else {
      gl.bindTexture(gl.TEXTURE_2D, retinaTex);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
      if (frameW !== retinaW || frameH !== retinaH) {
        retinaW = frameW;
        retinaH = frameH;
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, retinaW, retinaH, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        updateAspectLayout();
      }

      for (var i = 0; i < tileCount; i++) {
        if (off + 14 > ab.byteLength) break;
        var tx = dv.getUint16(off, true);
        var ty = dv.getUint16(off + 2, true);
        var tw = dv.getUint16(off + 4, true);
        var th = dv.getUint16(off + 6, true);
        var enc = dv.getUint8(off + 8);
        var dlen = dv.getUint32(off + 10, true);
        off += 14;
        if (off + dlen > ab.byteLength) break;

        var rawSize = tw * th * 4;
        if (rawSize > tileDecodeBuf.length) {
          tileDecodeBuf = new Uint8Array(rawSize);
        }

        if (enc === ENC_LZ4_BGRA) {
          var decBytes = lz4Decompress(srcU8, off, dlen, tileDecodeBuf, rawSize);
          if (decBytes === rawSize) {
            gl.texSubImage2D(gl.TEXTURE_2D, 0, tx, ty, tw, th, gl.RGBA, gl.UNSIGNED_BYTE, tileDecodeBuf.subarray(0, rawSize));
          }
        } else if (enc === ENC_RAW_BGRA && dlen === rawSize) {
          gl.texSubImage2D(gl.TEXTURE_2D, 0, tx, ty, tw, th, gl.RGBA, gl.UNSIGNED_BYTE, srcU8.subarray(off, off + dlen));
        }
        off += dlen;
      }
      if ((flags & TILE_FLAG_FULL_SYNC) !== 0 || !activeIsMotion) {
        activeIsMotion = false;
      }
    }

    if (!hasFirstFrame) {
      hasFirstFrame = true;
      streamLoader.classList.add('hidden');
    }

    frameCounter++;
    var now = Date.now();
    if (now - lastFpsTs >= 1000) {
      measuredFps = Math.round((frameCounter * 1000) / (now - lastFpsTs));
      frameCounter = 0;
      lastFpsTs = now;
      updateHud(retinaW, retinaH);
    }

    needsDraw = true;
  }

  // ---- Conexão WebSocket com Reconexão Automática ----
  function connectWS() {
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    var proto = (window.location.protocol === 'https:') ? 'wss://' : 'ws://';
    var url = proto + window.location.host + '/ws';

    connPill.className = 'conn-pill conn-connecting';
    connLabel.textContent = 'Conectando...';

    try {
      ws = new WebSocket(url);
      ws.binaryType = 'arraybuffer';
    } catch (e) {
      scheduleReconnect();
      return;
    }

    ws.onopen = function () {
      sendHello();
      if (currentMode !== MODE_IDLE) {
        sendControl(CTRL_SET_POSITION, currentPos);
        sendControl(CTRL_SET_PRESET, currentPreset);
        sendControl(CTRL_SET_MODE, currentMode);
        sendControl(CTRL_REQUEST_SYNC, 0);
      }
    };

    ws.onmessage = function (ev) {
      if (ev.data instanceof ArrayBuffer) {
        handleBinaryMessage(ev.data);
      }
    };

    ws.onclose = function () {
      connPill.className = 'conn-pill conn-offline';
      connLabel.textContent = 'Reconectando...';
      scheduleReconnect();
    };

    ws.onerror = function () {
      try { ws.close(); } catch (e) {}
    };
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      connectWS();
    }, 1200);
  }

  // ---- Controle de Telas ----
  function enterMode(mode) {
    currentMode = mode;
    hasFirstFrame = false;
    activeIsMotion = false;
    retinaW = 0; retinaH = 0;
    motionW = 0; motionH = 0;

    menuView.classList.add('hidden');
    displayView.classList.remove('hidden');
    streamLoader.classList.remove('hidden');
    loaderText.textContent = (mode === MODE_SECOND)
      ? 'Ativando Segunda Tela Retina 2048×1536...'
      : 'Iniciando Espelhamento Retina...';
    btnSwitchMode.textContent = (mode === MODE_SECOND) ? 'Ir p/ Espelho' : 'Ir p/ 2ª Tela';

    resizeCanvas();
    showToolbarTemporary();

    sendControl(CTRL_SET_POSITION, currentPos);
    sendControl(CTRL_SET_PRESET, currentPreset);
    sendControl(CTRL_SET_MODE, mode);
  }

  function returnToMenu() {
    currentMode = MODE_IDLE;
    hasFirstFrame = false;
    remoteCursor.classList.add('hidden');
    displayView.classList.add('hidden');
    menuView.classList.remove('hidden');
    sendControl(CTRL_SET_MODE, MODE_IDLE);
  }

  function showToolbarTemporary() {
    floatingBar.classList.remove('collapsed');
    if (autoHideTimer) clearTimeout(autoHideTimer);
    autoHideTimer = setTimeout(function () {
      floatingBar.classList.add('collapsed');
    }, 4000);
  }

  // ---- Helper de Tap sem disparo duplo ----
  function bindClick(el, fn) {
    if (!el) return;
    var lock = false;
    el.addEventListener('touchend', function (e) {
      e.preventDefault();
      e.stopPropagation();
      if (lock) return;
      lock = true;
      fn(e);
      setTimeout(function () { lock = false; }, 350);
    }, false);
    el.addEventListener('click', function (e) {
      e.stopPropagation();
      if (lock) return;
      fn(e);
    }, false);
  }

  bindClick(cardSecond, function () { enterMode(MODE_SECOND); });
  bindClick(cardMirror, function () { enterMode(MODE_MIRROR); });
  bindClick(btnBack, function () { returnToMenu(); });
  bindClick(btnSwitchMode, function () {
    enterMode(currentMode === MODE_SECOND ? MODE_MIRROR : MODE_SECOND);
  });
  bindClick(btnPreset, function () {
    currentPreset = (currentPreset + 1) % 3;
    btnPreset.textContent = presetNames[currentPreset];
    syncQuickBarUI();
    sendControl(CTRL_SET_PRESET, currentPreset);
    showToolbarTemporary();
  });
  bindClick(btnFit, function () {
    fillScreen = !fillScreen;
    btnFit.textContent = fillScreen ? 'Preencher' : 'Ajustar';
    updateAspectLayout();
    needsDraw = true;
    showToolbarTemporary();
  });
  bindClick(btnTouch, function () {
    touchEnabled = !touchEnabled;
    btnTouch.textContent = touchEnabled ? 'Toque: On' : 'Toque: Off';
    if (touchEnabled) btnTouch.classList.add('active');
    else btnTouch.classList.remove('active');
    showToolbarTemporary();
  });
  bindClick(btnKeyboard, function () {
    kbInput.focus();
    showToolbarTemporary();
  });
  bindClick(btnHideBar, function () {
    floatingBar.classList.add('collapsed');
  });
  bindClick(toolbarHandle, function () {
    if (floatingBar.classList.contains('collapsed')) {
      showToolbarTemporary();
    } else {
      floatingBar.classList.add('collapsed');
    }
  });

  // Botões da barra rápida do Menu
  var presetBtns = document.querySelectorAll('.pill-opt');
  var posBtns = document.querySelectorAll('.pos-opt');
  function syncQuickBarUI() {
    for (var i = 0; i < presetBtns.length; i++) {
      var v = parseInt(presetBtns[i].getAttribute('data-preset'), 10);
      if (v === currentPreset) presetBtns[i].classList.add('active');
      else presetBtns[i].classList.remove('active');
    }
    for (var j = 0; j < posBtns.length; j++) {
      var p = parseInt(posBtns[j].getAttribute('data-pos'), 10);
      if (p === currentPos) posBtns[j].classList.add('active');
      else posBtns[j].classList.remove('active');
    }
    btnPreset.textContent = presetNames[currentPreset];
  }
  for (var pi = 0; pi < presetBtns.length; pi++) {
    (function (btn) {
      bindClick(btn, function () {
        currentPreset = parseInt(btn.getAttribute('data-preset'), 10);
        syncQuickBarUI();
      });
    })(presetBtns[pi]);
  }
  for (var pj = 0; pj < posBtns.length; pj++) {
    (function (btn) {
      bindClick(btn, function () {
        currentPos = parseInt(btn.getAttribute('data-pos'), 10);
        syncQuickBarUI();
      });
    })(posBtns[pj]);
  }

  // ---- Teclado Virtual ----
  kbInput.addEventListener('input', function () {
    var val = kbInput.value;
    if (val) {
      for (var i = 0; i < val.length; i++) {
        sendInput(INPUT_KEY_CHAR, 0, 0, 0, val.charCodeAt(i), 0);
      }
      kbInput.value = '';
    }
  }, false);

  kbInput.addEventListener('keydown', function (e) {
    if (e.keyCode === 8) { sendInput(INPUT_KEY_SPECIAL, 0, 0, 0, 2, 0); e.preventDefault(); }
    else if (e.keyCode === 13) { sendInput(INPUT_KEY_SPECIAL, 0, 0, 0, 1, 0); e.preventDefault(); }
    else if (e.keyCode === 9) { sendInput(INPUT_KEY_SPECIAL, 0, 0, 0, 3, 0); e.preventDefault(); }
    else if (e.keyCode === 27) { sendInput(INPUT_KEY_SPECIAL, 0, 0, 0, 4, 0); e.preventDefault(); }
  }, false);

  // ---- Multi-Touch Completo (Clique, Duplo Clique, Arraste, Rolagem 2 Dedos, Clique Direito) ----
  function mapClientToNorm(cx, cy) {
    var nx = (cx - renderViewport.x) / (renderViewport.w || 1);
    var ny = (cy - renderViewport.y) / (renderViewport.h || 1);
    if (nx < 0) nx = 0; if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; if (ny > 1) ny = 1;
    return { x: nx, y: ny };
  }

  var gesture = {
    count: 0,
    startX: 0, startY: 0,
    lastX: 0, lastY: 0,
    dragging: false,
    scrolling: false,
    rightClicked: false,
    longPressTimer: null,
    lastTapTs: 0
  };

  glCanvas.addEventListener('touchstart', function (e) {
    if (currentMode === MODE_IDLE) return;
    e.preventDefault();

    if (gesture.longPressTimer) { clearTimeout(gesture.longPressTimer); gesture.longPressTimer = null; }
    var n = e.touches.length;
    gesture.count = n;
    gesture.dragging = false;
    gesture.scrolling = false;
    gesture.rightClicked = false;

    if (n === 3) {
      if (floatingBar.classList.contains('collapsed')) showToolbarTemporary();
      else floatingBar.classList.add('collapsed');
      return;
    }
    if (!touchEnabled) return;

    if (n === 1) {
      var t = e.touches[0];
      gesture.startX = t.clientX;
      gesture.startY = t.clientY;
      gesture.lastX = t.clientX;
      gesture.lastY = t.clientY;
      var pt = mapClientToNorm(t.clientX, t.clientY);
      sendInput(INPUT_MOVE, pt.x, pt.y, 0, 0, 0);

      gesture.longPressTimer = setTimeout(function () {
        if (!gesture.dragging && gesture.count === 1) {
          gesture.rightClicked = true;
          sendInput(INPUT_RIGHT_DOWN, pt.x, pt.y, 1, 0, 0);
          sendInput(INPUT_RIGHT_UP, pt.x, pt.y, 1, 0, 0);
        }
      }, 500);
    } else if (n === 2) {
      gesture.lastX = (e.touches[0].clientX + e.touches[1].clientX) * 0.5;
      gesture.lastY = (e.touches[0].clientY + e.touches[1].clientY) * 0.5;
      gesture.startX = gesture.lastX;
      gesture.startY = gesture.lastY;
    }
  }, false);

  glCanvas.addEventListener('touchmove', function (e) {
    if (currentMode === MODE_IDLE || !touchEnabled) return;
    e.preventDefault();

    if (e.touches.length === 1 && gesture.count === 1 && !gesture.rightClicked) {
      var t = e.touches[0];
      var dx = t.clientX - gesture.startX;
      var dy = t.clientY - gesture.startY;
      var pt = mapClientToNorm(t.clientX, t.clientY);
      if (!gesture.dragging && (dx * dx + dy * dy) > 64) {
        gesture.dragging = true;
        if (gesture.longPressTimer) { clearTimeout(gesture.longPressTimer); gesture.longPressTimer = null; }
        var startPt = mapClientToNorm(gesture.startX, gesture.startY);
        sendInput(INPUT_LEFT_DOWN, startPt.x, startPt.y, 1, 0, 0);
      }
      if (gesture.dragging) {
        sendInput(INPUT_LEFT_DRAG, pt.x, pt.y, 1, 0, 0);
      }
      gesture.lastX = t.clientX;
      gesture.lastY = t.clientY;
    } else if (e.touches.length === 2) {
      var mx = (e.touches[0].clientX + e.touches[1].clientX) * 0.5;
      var my = (e.touches[0].clientY + e.touches[1].clientY) * 0.5;
      var sdx = (mx - gesture.lastX) * 2.2;
      var sdy = (my - gesture.lastY) * 2.2;
      if (Math.abs(sdx) > 1 || Math.abs(sdy) > 1) {
        gesture.scrolling = true;
        sendInput(INPUT_SCROLL, sdx, sdy, 0, 0, 0);
      }
      gesture.lastX = mx;
      gesture.lastY = my;
    }
  }, false);

  glCanvas.addEventListener('touchend', function (e) {
    if (currentMode === MODE_IDLE || !touchEnabled) return;
    e.preventDefault();
    if (gesture.longPressTimer) { clearTimeout(gesture.longPressTimer); gesture.longPressTimer = null; }

    if (gesture.count === 1 && !gesture.rightClicked) {
      var pt = mapClientToNorm(gesture.lastX, gesture.lastY);
      if (gesture.dragging) {
        sendInput(INPUT_LEFT_UP, pt.x, pt.y, 1, 0, 0);
      } else {
        var now = Date.now();
        if (now - gesture.lastTapTs < 320) {
          sendInput(INPUT_DOUBLE_CLICK, pt.x, pt.y, 2, 0, 0);
          gesture.lastTapTs = 0;
        } else {
          sendInput(INPUT_LEFT_DOWN, pt.x, pt.y, 1, 0, 0);
          sendInput(INPUT_LEFT_UP, pt.x, pt.y, 1, 0, 0);
          gesture.lastTapTs = now;
        }
      }
    } else if (gesture.count === 2 && !gesture.scrolling && e.touches.length === 0) {
      // Toque rápido com 2 dedos = Clique Direito!
      var rpt = mapClientToNorm(gesture.startX, gesture.startY);
      sendInput(INPUT_RIGHT_DOWN, rpt.x, rpt.y, 1, 0, 0);
      sendInput(INPUT_RIGHT_UP, rpt.x, rpt.y, 1, 0, 0);
    }

    if (e.touches.length === 0) {
      gesture.count = 0;
      gesture.dragging = false;
      gesture.scrolling = false;
    }
  }, false);

  // Suporte a mouse se aberto no navegador de um PC para teste
  var mouseDown = false;
  glCanvas.addEventListener('mousedown', function (e) {
    if (currentMode === MODE_IDLE || !touchEnabled) return;
    mouseDown = true;
    var pt = mapClientToNorm(e.clientX, e.clientY);
    sendInput(e.button === 2 ? INPUT_RIGHT_DOWN : INPUT_LEFT_DOWN, pt.x, pt.y, 1, 0, 0);
  }, false);
  glCanvas.addEventListener('mousemove', function (e) {
    if (currentMode === MODE_IDLE || !touchEnabled || !mouseDown) return;
    var pt = mapClientToNorm(e.clientX, e.clientY);
    sendInput(INPUT_LEFT_DRAG, pt.x, pt.y, 1, 0, 0);
  }, false);
  glCanvas.addEventListener('mouseup', function (e) {
    if (!mouseDown) return;
    mouseDown = false;
    var pt = mapClientToNorm(e.clientX, e.clientY);
    sendInput(e.button === 2 ? INPUT_RIGHT_UP : INPUT_LEFT_UP, pt.x, pt.y, 1, 0, 0);
  }, false);
  glCanvas.addEventListener('contextmenu', function (e) { e.preventDefault(); }, false);

  window.addEventListener('resize', resizeCanvas, false);
  window.addEventListener('orientationchange', function () {
    setTimeout(resizeCanvas, 200);
  }, false);

  // Inicialização
  initWebGL();
  connectWS();
  window.requestAnimationFrame(renderLoop);
})();
