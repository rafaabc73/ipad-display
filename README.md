# 🍏 iPad Display Pro v2.0 — Segunda Tela Retina (2048×1536) & Espelhamento a 60 FPS

> Transforme qualquer iPad — inclusive modelos antigos de 32-bit como o **iPad 4 com iOS 10.3.3** — em uma **Segunda Tela Estendida Retina real (`2048×1536` 1:1)** ou **Espelhamento de Tela** para **macOS e Windows**, via **cabo USB Lightning** ou **Wi-Fi**, com nitidez idêntica à tela nativa do iPad e fluidez de até **60 FPS**.

🔗 **Repositório:** https://github.com/rafaabc73/ipad-display

---

## 🌟 Principais Recursos

- 🖥️ **Segunda Tela Estendida Retina Verdadeira (HiDPI 2× no macOS)**:
  - Cria um monitor virtual nativo usando `CGVirtualDisplay` em **HiDPI 2× real** (`1024×768` lógico = **`2048×1536` pixels físicos**, encaixe exato 1:1 na tela Retina do iPad 4) ou `1280×960 @ 2×` (*Mais Espaço*).
  - Posicionamento configurável em tempo real (**Direita, Esquerda, Acima ou Abaixo** da tela principal).
  - Ao sair ou alternar para *Espelhar Tela*, o monitor virtual é destruído automaticamente (nunca deixa tela fantasma prendendo o mouse).
- 🪞 **Espelhamento de Tela Sem Distorção**:
  - Duplica o monitor principal preservando a proporção exata da tela do computador (ex.: `2048×1280` em MacBooks 16:10 ou `1920×1080` em monitores 16:9).
- 💎 **Nitidez Igual à Tela do iPad + Fluidez 60 FPS (Motor Híbrido)**:
  - **Textos, código, planilhas e navegação**: apenas os blocos alterados (`128×128`) trafegam em **LZ4 BGRA 100% lossless** (sem borrão ou artefatos de JPEG).
  - **Vídeos, rolagem rápida e movimento intenso**: ativa aceleração de vídeo por hardware (**VideoToolbox H.264** no App Nativo iOS, ou RGB565 adaptativo no PWA) a até **60 FPS**, e 110 ms após parar o movimento aplica automaticamente o **passe Retina `2048×1536` lossless**.
  - **Cursor 60 Hz independente**: o ponteiro do mouse é renderizado separadamente na GPU do iPad com pacotes de 16 bytes — movimentação instantânea mesmo quando o conteúdo da tela está parado.
- 📱 **Dois Formatos de App no iPad (mesmo servidor)**:
  - **App Nativo iOS Universal (`dist/iPadDisplay.ipa` — `armv7s` + `arm64`, iOS 10.0+)**: conexão plug-and-play direto pelo cabo USB via **`usbmuxd`** em Mac e Windows (sem Compartilhamento de Internet nem Wi-Fi) + OpenGL ES 2.0 + decodificação H.264 em hardware no chip A6X.
  - **App Web / PWA Retina (`public/`)**: funciona direto no Safari (iOS 10.3.3+) e em tela cheia na Tela de Início, **sem Apple ID, sem assinatura e sem expirar**, usando WebGL 1.0 + WebSocket binário + LZ4 lossless `2048×1536`.
- 💻 **Compatível com macOS e Windows 10/11**:
  - **macOS**: motor nativo em Objective-C/C (`dist/iPad Display.app` na barra de menus ou `./start.sh`), sem depender de Node.js.
  - **Windows**: executável único portável em Go (`dist/iPadDisplay-Windows.exe`) com PWA embutido e suporte a cabo USB via `usbmuxd`.
- 👆 **Multi-Touch Completo + Teclado Virtual**:
  - Clique esquerdo, duplo clique, arrastar janelas/texto, rolagem suave com 2 dedos, clique direito e envio de texto pelo teclado do iPad.

---

## 🧠 Como o Projeto Funciona (Arquitetura Técnica)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    COMPUTADOR HOST (macOS ou Windows)                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. Monitor Virtual HiDPI 2×                                            │
│     • macOS: CGVirtualDisplay (1024×768 @ 2× = 2048×1536 físicos)       │
│     • Windows: Monitor secundário / Virtual Display Driver (MTT VDD)    │
│                                                                         │
│  2. Motor de Captura Híbrido 60 FPS (Protocolo Binário IPD2)            │
│     • Captura sem cursor (ScreenCaptureKit no Mac / BitBlt no Windows)  │
│     • Diff rápido por tiles 128×128 contra o quadro anterior            │
│     ├── ≤ 35% alterado → LZ4 BGRA 100% Lossless (Retina 2048×1536)      │
│     ├── > 35% alterado → Hardware H.264 (VideoToolbox ≤1080p @ 60fps)   │
│     │                    ou Half-Res RGB565+LZ4 (para PWA WebGL)        │
│     ├── 110 ms após parar → Passe automático Lossless 2048×1536         │
│     └── Timer 60 Hz → Coordenadas do cursor separadas (16 bytes)        │
│                                                                         │
│  3. Transporte & Controle de Fluxo (Zero Buffer Bloat)                  │
│     • Cabo USB Plug & Play: túnel usbmuxd → porta 23456 do iPad         │
│     • Rede Local / USB Ethernet: TCP :23456 (App Nativo + Bonjour)      │
│     • HTTP + WebSocket Binário RFC 6455 :8080 (App Web / PWA)           │
│     • Controle de fluxo fim-a-fim via FRAME_ACK (fila máxima = 2)       │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                 Cabo USB (~0,7 ms)  │  ou Wi-Fi (mesma rede)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          iPAD (iOS 10.3.3+)                             │
├────────────────────────────────────┬────────────────────────────────────┤
│   App Nativo iOS (.ipa armv7s/64)  │      App Web / PWA (Safari)        │
│   • OpenGL ES 2.0 (2048×1536 1:1)  │  • WebGL 1.0 (2048×1536 1:1)       │
│   • Textura BGRA Lossless (LZ4 C)  │  • Shader BGRA→RGBA na GPU         │
│   • VideoToolbox H.264 Zero-Copy   │  • Descompressor LZ4 ES5 Zero-GC   │
│     (CVOpenGLESTextureCache NV12)  │  • Motion RGB565 + Snap Retina     │
│   • Cursor Sprite OpenGL 60 Hz     │  • Cursor Composited GPU 60 Hz     │
│   • Gestos Multi-Touch + Teclado   │  • Gestos Multi-Touch + Teclado    │
└────────────────────────────────────┴────────────────────────────────────┘
```

### Por que o motor híbrido entrega nitidez Retina E 60 FPS no iPad 4?
1. **Limite de hardware do chip Apple A6X**: o decodificador H.264 em hardware do iPad 4 suporta até `1080p` (`1920×1080`), não `2048×1536`. Por isso, durante vídeos ou rolagem intensa, o host usa VideoToolbox H.264 em `1440×1080` (4:3) ou `1728×1080` (16:10) — garantindo 60 FPS fluidos com uso mínimo de CPU — e assim que o movimento estabiliza (110 ms), o host envia os tiles alterados em **`2048×1536` BGRA 100% lossless via LZ4**, deixando textos e bordas idênticos à tela nativa do iPad.
2. **Zero trabalho em tela parada**: quando nada muda na tela, `0 bytes` são transmitidos. Mexer o mouse envia apenas pacotes de 16 bytes para mover o sprite do cursor na GPU do iPad a 60 Hz.
3. **Sem acúmulo de latência**: quadros de movimento respeitam o `FRAME_ACK` do iPad; se o cliente ainda estiver decodificando, o host descarta quadros intermediários sem enfileirar atraso no TCP.

---

## 🚀 Como Usar

### 1. Clonar e Compilar o Projeto (macOS)

**Pré-requisitos no Mac:** macOS 12.3+ (testado no macOS 14 Sonoma) e Xcode Command Line Tools (`xcode-select --install`). Para compilar o executável Windows opcional, tenha `go` instalado.

```bash
git clone https://github.com/rafaabc73/ipad-display.git
cd ipad-display

# Compilar tudo (Host macOS, iPad Display.app, App Nativo iOS .ipa e Host Windows .exe)
./scripts/build_all.sh
```

Artefatos gerados em `dist/`:
- `dist/iPad Display.app` — aplicativo macOS com ícone na barra de menus
- `dist/iPadDisplay.ipa` — aplicativo nativo universal iOS (`armv7s` + `arm64`, iOS 10.0+)
- `dist/iPadDisplay-Windows.exe` — executável único portável para Windows 10/11

---

### 2. Rodar no Mac

**Pelo aplicativo de barra de menus:**
```bash
open "dist/iPad Display.app"
```
**Ou pelo terminal (compila automaticamente se necessário):**
```bash
./start.sh
```

> **Permissões do macOS (1ª execução):** autorize **Gravação de Tela** (para transmitir a tela) e **Acessibilidade** (para o toque do iPad controlar cliques/rolagem) em *Ajustes do Sistema → Privacidade e Segurança*.

---

### 3. Conectar no iPad

#### Opção A — App Nativo iOS (`dist/iPadDisplay.ipa`) — Recomendada (60 FPS + Cabo USB em Mac e Windows)

1. **Instalar o `.ipa` no iPad:**
   - **iPad original (sem jailbreak) via Sideloadly:**
     1. Instale o [Sideloadly](https://sideloadly.io/) no Mac ou Windows.
     2. Conecte o iPad via cabo USB, arraste `dist/iPadDisplay.ipa` para o Sideloadly, informe seu Apple ID e clique em **Start**.
     3. No iPad, acesse **Ajustes → Geral → Gerenciamento de Dispositivo** e confie no perfil.
     4. *(Regra da Apple: em Apple ID gratuito, o certificado expira após 7 dias e basta clicar em Start novamente no Sideloadly; em conta Apple Developer paga dura 1 ano.)*
   - **iPad com Jailbreak (iOS 10.3.3 `h3lix` + `AppSync Unified`) — Permanente, nunca expira:**
     ```bash
     brew install ideviceinstaller
     ideviceinstaller -i dist/iPadDisplay.ipa
     ```
2. **Usar no dia a dia:**
   - Conecte o cabo Lightning no Mac ou Windows com o **iPad Display** rodando.
   - Abra o app **iPad Display** no iPad: ele detecta o computador automaticamente pelo cabo USB (`usbmuxd`) ou Wi-Fi (Bonjour).
   - Toque em **Segunda Tela** ou **Espelhar Tela**.

#### Opção B — App Web / PWA Retina (Zero Instalação / Nunca Expira)

1. **Via Cabo USB no Mac (~0,7 ms):** com o *Compartilhamento de Internet → iPad USB* ativo no Mac, abra o Safari no iPad e acesse `http://192.168.2.1:8080`.
2. **Via Wi-Fi (Mac ou Windows):** com ambos na mesma rede, acesse `http://<IP-DO-COMPUTADOR>:8080` (exibido no terminal ou no menu do app no Mac).
3. **Instalar como app em tela cheia:** no Safari do iPad, toque em **Compartilhar** → **"Adicionar à Tela de Início"** e abra pelo ícone criado.

---

### 4. Rodar no Windows 10 / 11

1. Copie `dist/iPadDisplay-Windows.exe` para o PC Windows e abra com duplo clique (não exige Node.js, Python ou runtime adicional).
2. **Conexão por Cabo USB (App Nativo):** tenha o **Apple Devices** (Microsoft Store) ou **iTunes** instalado para o serviço *Apple Mobile Device Support (`usbmuxd`)* na porta `27015`. Plugar o cabo e abrir o app no iPad conecta automaticamente.
3. **Conexão por Wi-Fi (App Nativo ou PWA):** abra `http://<IP-DO-WINDOWS>:8080` no Safari ou conecte via IP no App Nativo.
4. **Segunda Tela Estendida no Windows:** o modo *Espelhar Tela* já funciona imediatamente. Para criar um 2º monitor virtual sem monitor físico extra, execute `scripts/install_windows_vdd.bat` para instalar o driver gratuito e assinado *Virtual Display Driver (MTT)*.

---

## 👆 Gestos e Controles na Tela do iPad

| Gesto / Controle | Ação no Computador |
| :--- | :--- |
| **Toque com 1 dedo** | Clique esquerdo |
| **Toque duplo com 1 dedo** | Duplo clique |
| **Arrastar com 1 dedo** | Clicar e arrastar (mover janelas, selecionar texto) |
| **Arrastar com 2 dedos** | Rolagem suave (vertical e horizontal) |
| **Toque com 2 dedos** ou **segurar 1 dedo (0,5s)** | Clique direito |
| **Toque com 3 dedos** ou tocar na **alça no topo** | Mostrar / ocultar barra flutuante de controles |
| **Botão Teclado** (na barra flutuante) | Abre o teclado do iPad e digita direto no Mac/Windows |

### Presets de Qualidade disponíveis
- **Retina 1:1 (Padrão)**: `1024×768 @ 2×` = `2048×1536` físicos exatos — máxima nitidez de texto.
- **Mais Espaço**: `1280×960 @ 2×` (`2560×1920` renderizados em `2048×1536`) — 25% mais área útil mantendo nitidez Retina.
- **Wi-Fi Rápido**: `1024×768` (`1×`) — indicado para redes Wi-Fi congestionadas.

---

## 📁 Estrutura do Repositório

```
ipad-display/
├── shared/
│   ├── protocol.h                   # Definição do protocolo binário unificado IPD2
│   └── lz4/                         # Biblioteca LZ4 v1.10.0 embarcada (sem dependências)
├── host/
│   ├── macos/
│   │   ├── main.m                   # Entrypoint, barra de menus macOS (NSStatusItem) e CLI --headless
│   │   ├── virtual_display.h/.m     # Gerenciador CGVirtualDisplay HiDPI 2×
│   │   ├── capture_engine.h/.m      # ScreenCaptureKit 60fps + diff LZ4 + VideoToolbox H.264 + cursor 60Hz
│   │   ├── input_injector.h/.m      # Injeção CGEvent (mouse, arraste, scroll, teclado)
│   │   ├── usbmux_bridge.h/.m       # Túnel USB plug-and-play via /var/run/usbmuxd
│   │   └── net_server.h/.m          # Servidor HTTP + WebSocket RFC 6455 + TCP + Bonjour
│   └── windows/
│       ├── main.go                  # Host Windows standalone com PWA embutido (embed.FS)
│       ├── capture_windows.go       # Captura DPI-aware, diff LZ4, cursor 60Hz e SendInput
│       ├── usbmux.go                # Túnel USB via Apple Mobile Device Support (127.0.0.1:27015)
│       ├── protocol.go              # Protocolo IPD2, WebSocket e compressor LZ4 puro em Go
│       └── protocol_test.go         # Testes unitários do compressor LZ4
├── ios/
│   ├── AppDelegate.h/.m             # Ciclo de vida iOS (mantém tela sempre acesa)
│   ├── HomeViewController.h/.m      # Menu nativo (Segunda Tela / Espelhar / Presets / IP Manual)
│   ├── DisplayViewController.h/.m   # Tela cheia, gestos multi-touch, barra flutuante e teclado
│   ├── GLDisplayView.h/.m           # Renderizador OpenGL ES 2.0 (Retina BGRA + H.264 NV12 + Cursor)
│   ├── VideoDecoder.h/.m            # Decodificador hardware VideoToolbox (H.264 <= 1080p)
│   ├── ConnectionManager.h/.m       # Listener USB (:23456) + Bonjour Wi-Fi + IP manual
│   ├── ios_compat.c                 # Shims compatíveis com iPhoneOS10.3.sdk
│   ├── Info.plist                   # Metadados do app iOS 10.0+
│   └── build_ipa.sh                 # Script de build universal armv7s + arm64 (.ipa)
├── public/
│   ├── index.html                   # Interface PWA Retina
│   ├── styles.css                   # Estilos 100% compatíveis com Safari iOS 10.3.3
│   ├── app.js                       # Cliente ES5 WebGL 1.0 + WebSocket binário + LZ4 zero-GC
│   ├── manifest.json                # Manifesto PWA
│   └── icon-192.png / icon-512.png  # Ícones Retina
├── scripts/
│   ├── build_all.sh                 # Compila macOS + .app + iOS .ipa + Windows .exe
│   └── install_windows_vdd.bat      # Auxiliar para instalar Virtual Display Driver no Windows
├── start.sh                         # Inicialização rápida em 1 comando no macOS
└── README.md
```

---

## 🛠️ Solução de Problemas

- **Tela preta no Mac ao iniciar**: vá em *Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela*, remova e adicione novamente o Terminal (ou `iPad Display.app`) e reinicie o aplicativo.
- **Toque no iPad não clica no Mac**: habilite o Terminal / `iPad Display.app` em *Ajustes do Sistema → Privacidade e Segurança → Acessibilidade*.
- **Cabo USB não conecta no Windows**: certifique-se de que o **Apple Devices** ou **iTunes** está instalado, que o iPad foi confiado ("Confiar neste computador") e que o Firewall do Windows permite conexões na rede privada.
- **Compilar `.ipa` em outro Mac**: o script `ios/build_ipa.sh` baixa automaticamente o `iPhoneOS10.3.sdk` caso o caminho padrão não exista (ou defina `IOS_SDK=/caminho/para/iPhoneOS10.3.sdk`).

---

## 📄 Licença

Distribuído sob a licença **MIT**. Consulte o arquivo [LICENSE](LICENSE) para mais detalhes.
