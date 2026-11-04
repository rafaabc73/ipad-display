// iPad Display - Cliente PWA Otimizado para iOS 10.3.3 (Hardware Native Zero Delay)
(function () {
  'use strict';

  // Elementos do DOM
  var menuView = document.getElementById('menuView');
  var streamView = document.getElementById('streamView');
  var cardMirror = document.getElementById('cardMirror');
  var cardSecond = document.getElementById('cardSecond');
  var btnMirror = document.querySelector('.btn-mirror');
  var btnSecond = document.querySelector('.btn-second');
  var streamContainer = document.getElementById('streamContainer');
  var streamImg = document.getElementById('streamImg');
  var streamLoader = document.getElementById('streamLoader');
  var streamControls = document.getElementById('streamControls');
  var btnBack = document.getElementById('btnBack');
  var btnQualityToggle = document.getElementById('btnQualityToggle');
  var qualityLabel = document.getElementById('qualityLabel');
  var btnFitToggle = document.getElementById('btnFitToggle');
  var fitLabel = document.getElementById('fitLabel');
  var btnTouchToggle = document.getElementById('btnTouchToggle');
  var touchLabel = document.getElementById('touchLabel');
  var btnFullscreen = document.getElementById('btnFullscreen');
  var streamModeBadge = document.getElementById('streamModeBadge');
  var fpsBadge = document.getElementById('fpsBadge');

  // Garante visibilidade e acessibilidade de clique inicial no Safari iOS 10
  if (streamView) {
    streamView.style.display = 'none';
  }
  if (menuView) {
    menuView.style.display = 'flex';
  }

  // Estado da aplicação
  var currentMode = 'none';
  var touchEnabled = true;
  var isFillScreen = false;

  // Presets de Resolução e Desempenho (Otimizados para iPad 4 e Cabo Lightning)
  var qualityPresets = [
    {
      label: '🔥 Alta Definição (1280x960)',
      badge: 'HD Retina • 30 FPS',
      secondW: 1280,
      secondH: 960,
      mirrorW: 1440,
      mirrorH: 900,
      quality: 0.55,
      fps: 30
    },
    {
      label: '💎 Retina Total (1600x1200)',
      badge: 'Retina 2K • Máxima Nitidez',
      secondW: 1600,
      secondH: 1200,
      mirrorW: 1440,
      mirrorH: 900,
      quality: 0.65,
      fps: 30
    },
    {
      label: '⚡ Modo Rápido (1024x768)',
      badge: 'Zero Delay • 30 FPS',
      secondW: 1024,
      secondH: 768,
      mirrorW: 1280,
      mirrorH: 800,
      quality: 0.40,
      fps: 30
    }
  ];
  var currentPresetIndex = 0;

  // Requisição AJAX compatível com Safari iOS 10
  function sendJson(url, data, callback) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.onreadystatechange = function () {
      if (xhr.readyState === 4 && callback) {
        try {
          callback(null, JSON.parse(xhr.responseText));
        } catch (e) {
          callback(e, null);
        }
      }
    };
    xhr.send(JSON.stringify(data));
  }

  // Ativa a transmissão
  function activateMode(mode) {
    currentMode = mode;

    if (mode === 'mirror') {
      streamModeBadge.textContent = 'Espelhando Mac';
      streamModeBadge.style.color = '#0071e3';
    } else {
      streamModeBadge.textContent = 'Segunda Tela HD';
      streamModeBadge.style.color = '#34c759';
    }

    fpsBadge.textContent = qualityPresets[currentPresetIndex].badge;

    // Muda a tela visual imediatamente (garante display: none / flex)
    menuView.classList.add('hidden');
    menuView.style.display = 'none';
    streamView.classList.remove('hidden');
    streamView.style.display = 'flex';
    streamLoader.style.display = 'flex';

    var loaderText = document.getElementById('loaderText');
    if (loaderText) {
      loaderText.textContent = (mode === 'second') ? 'Conectando à Segunda Tela Retina...' : 'Conectando ao monitor do Mac...';
    }

    // Inicia a recepção de imagem nativa IMEDIATAMENTE
    iniciarStream(mode);

    // Envia modo e configurações para o servidor em segundo plano
    var preset = qualityPresets[currentPresetIndex];
    var w = (mode === 'second') ? preset.secondW : preset.mirrorW;
    var h = (mode === 'second') ? preset.secondH : preset.mirrorH;

    sendJson('/api/mode', { mode: mode });
    sendJson('/api/settings', {
      quality: preset.quality,
      fps: preset.fps,
      width: w,
      height: h
    });
  }

  function iniciarStream(mode) {
    if (!streamImg) return;
    streamImg.style.display = 'block';
    streamImg.src = '/stream?mode=' + mode + '&t=' + Date.now();
    streamImg.onload = function () {
      if (streamLoader) {
        streamLoader.style.display = 'none';
      }
    };
  }

  function returnToMenu() {
    currentMode = 'none';
    if (streamImg) {
      streamImg.src = 'about:blank';
    }

    streamView.classList.add('hidden');
    streamView.style.display = 'none';
    menuView.classList.remove('hidden');
    menuView.style.display = 'flex';
  }

  // Mapeamento proporcional de clique na tela do iPad
  function handleScreenTouch(clientX, clientY) {
    if (!touchEnabled || currentMode === 'none') return;
    if (!streamImg) return;

    var rect = streamImg.getBoundingClientRect();
    var preset = qualityPresets[currentPresetIndex];
    var naturalW = (currentMode === 'second' ? preset.secondW : preset.mirrorW);
    var naturalH = (currentMode === 'second' ? preset.secondH : preset.mirrorH);

    var containerW = rect.width;
    var containerH = rect.height;

    var renderW, renderH, offsetX, offsetY;

    if (isFillScreen) {
      renderW = containerW;
      renderH = containerH;
      offsetX = 0;
      offsetY = 0;
    } else {
      var imageAspect = naturalW / naturalH;
      var containerAspect = containerW / containerH;

      if (containerAspect > imageAspect) {
        renderH = containerH;
        renderW = renderH * imageAspect;
        offsetX = (containerW - renderW) / 2;
        offsetY = 0;
      } else {
        renderW = containerW;
        renderH = renderW / imageAspect;
        offsetX = 0;
        offsetY = (containerH - renderH) / 2;
      }
    }

    var clickX = clientX - rect.left - offsetX;
    var clickY = clientY - rect.top - offsetY;

    if (clickX < 0 || clickX > renderW || clickY < 0 || clickY > renderH) {
      return;
    }

    var normX = clickX / renderW;
    var normY = clickY / renderH;

    normX = Math.max(0, Math.min(1, normX));
    normY = Math.max(0, Math.min(1, normY));

    // Envia coordenadas de clique para o Mac
    sendJson('/api/click', {
      x: normX,
      y: normY,
      mode: currentMode
    });
  }

  // Helper universal de clique e toque para Safari iOS 10
  function bindTap(element, handler) {
    if (!element) return;
    var touchFired = false;
    element.addEventListener('touchend', function (e) {
      touchFired = true;
      e.preventDefault();
      handler(e);
      setTimeout(function () { touchFired = false; }, 400);
    }, false);

    element.addEventListener('click', function (e) {
      if (!touchFired) {
        handler(e);
      }
    }, false);
  }

  // Binda eventos em ambos os cards e botões
  bindTap(cardMirror, function () { activateMode('mirror'); });
  bindTap(btnMirror, function () { activateMode('mirror'); });
  bindTap(cardSecond, function () { activateMode('second'); });
  bindTap(btnSecond, function () { activateMode('second'); });
  bindTap(btnBack, function () { returnToMenu(); });

  // Alternar Resolução e Desempenho
  bindTap(btnQualityToggle, function () {
    currentPresetIndex = (currentPresetIndex + 1) % qualityPresets.length;
    var preset = qualityPresets[currentPresetIndex];
    qualityLabel.textContent = preset.label;
    fpsBadge.textContent = preset.badge;

    var w = (currentMode === 'second') ? preset.secondW : preset.mirrorW;
    var h = (currentMode === 'second') ? preset.secondH : preset.mirrorH;

    sendJson('/api/settings', {
      quality: preset.quality,
      fps: preset.fps,
      width: w,
      height: h
    });
  });

  // Alternar Ajustar / Preencher
  bindTap(btnFitToggle, function () {
    isFillScreen = !isFillScreen;
    if (isFillScreen) {
      if (streamImg) streamImg.classList.add('fill-screen');
      fitLabel.textContent = 'Preencher';
    } else {
      if (streamImg) streamImg.classList.remove('fill-screen');
      fitLabel.textContent = 'Ajustar';
    }
  });

  // Alternar Toque como Clique
  bindTap(btnTouchToggle, function () {
    touchEnabled = !touchEnabled;
    if (touchEnabled) {
      btnTouchToggle.classList.add('active');
      touchLabel.textContent = 'Toque';
    } else {
      btnTouchToggle.classList.remove('active');
      touchLabel.textContent = 'Inativo';
    }
  });

  // Tela Cheia
  bindTap(btnFullscreen, function () {
    var doc = document.documentElement;
    if (!document.fullscreenElement && !document.webkitFullscreenElement) {
      if (doc.requestFullscreen) {
        doc.requestFullscreen();
      } else if (doc.webkitRequestFullscreen) {
        doc.webkitRequestFullscreen();
      }
    } else {
      if (document.exitFullscreen) {
        document.exitFullscreen();
      } else if (document.webkitExitFullscreen) {
        document.webkitExitFullscreen();
      }
    }
  });

  // Gerenciador de Toque (Diferencia toque rápido de arrasto)
  var touchStartTime = 0;
  var touchMoved = false;

  function onTouchStart(e) {
    touchStartTime = Date.now();
    touchMoved = false;
  }

  function onTouchMove(e) {
    touchMoved = true;
  }

  function onTouchEnd(e) {
    var touchDuration = Date.now() - touchStartTime;
    if (!touchMoved && touchDuration < 450 && e.changedTouches && e.changedTouches.length > 0) {
      var t = e.changedTouches[0];
      handleScreenTouch(t.clientX, t.clientY);
    }
  }

  var container = streamContainer || streamImg;
  if (container) {
    container.addEventListener('touchstart', onTouchStart, { passive: false });
    container.addEventListener('touchmove', onTouchMove, { passive: false });
    container.addEventListener('touchend', onTouchEnd, { passive: false });
    container.addEventListener('click', function (e) { handleScreenTouch(e.clientX, e.clientY); });
  }

  document.addEventListener('touchmove', function (e) {
    if (currentMode !== 'none') {
      e.preventDefault();
    }
  }, { passive: false });

})();
