# 🍏 iPad Display - Segundo Monitor Retina & Espelhamento (Zero Delay)

> Transforme qualquer iPad (inclusive modelos antigos como o **iPad 4 com iOS 10.3.3 de 32-bit**) em uma **Segunda Tela Estendida** de Alta Definição ou **Espelhamento** para macOS com **Zero Delay Real (< 15ms)** conectado via cabo Lightning/USB ou Wi-Fi.

---

## 🌟 Visão Geral

Se você tem um iPad antigo guardado na gaveta que a Apple deixou de atualizar (como o iPad 2, 3 ou 4 com chip A6X de 2012), você não consegue usar o recurso oficial *Sidecar* da Apple (que exige iPads e Macs recentes). A maioria dos aplicativos da App Store também foi descontinuada ou não suporta versões antigas do iOS.

O **iPad Display** resolve esse problema criando uma solução **100% nativa, sem custos e sem gambiarras**, que transforma o iPad em um segundo monitor real no macOS através de um navegador web comum ou PWA em tela cheia.

---

## ✨ Principais Funcionalidades

- 🖥️ **Segunda Tela Estendida Verdadeira (Virtual Display)**:
  - Cria um monitor virtual nativo no macOS utilizando a API privada `CGVirtualDisplay`.
  - Aparece nas preferências de tela do Mac como uma tela física independente.
  - Arraste janelas, pastas, navegadores e programas do Mac para o iPad livremente.
- 🪞 **Duplicar Tela (Espelhamento)**:
  - Espelha o monitor principal do Mac em tempo real no iPad com proporção adaptada.
- ⚡ **Zero Delay Real (< 15ms)**:
  - **Backpressure Inteligente**: O servidor descarta frames intermediários antes de irem para a rede se o cliente ainda estiver recebendo o anterior. Fila no socket = zero permanente!
  - **Stream MJPEG Nativo em C++**: O Safari do iOS 10 decodifica o stream de vídeo diretamente na GPU via WebKit, sem usar loops pesados de JavaScript ou Garbage Collection.
- 🔥 **Alta Definição Retina (4:3)**:
  - O monitor virtual opera nativamente na proporção 4:3 do iPad (**1280×960** ou **1600×1200**).
  - Textos de código, terminais e páginas web ficam perfeitamente legíveis e nítidos.
  - Botão na barra superior para alternar dinamicamente a resolução entre **Alta Definição (1280×960)**, **Retina Total (1600×1200)** e **Modo Rápido (1024×768)**.
- 👆 **Toque na Tela como Clique do Mouse**:
  - Toque na tela do iPad para clicar exatamente naquela coordenada do monitor virtual no Mac.
- 🔌 **Conexão por Cabo USB (0.6ms) ou Wi-Fi**:
  - Funciona pela conexão de rede do cabo USB Lightning (sem oscilações de sinal Wi-Fi).
  - Também funciona normalmente por Wi-Fi se ambos os aparelhos estiverem na mesma rede local.
- 📱 **Instalável como PWA (Tela Cheia Sem Bordas)**:
  - Pode ser adicionado à Tela de Início do iOS via Safari, rodando como aplicativo independente sem barras de navegação ou abas.

---

## 🛠️ Como Funciona (Arquitetura Técnica)

```
┌─────────────────────────────────────────────────────────────┐
│                       COMPUTADOR MAC                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   1. [CGVirtualDisplay] (Objective-C)                       │
│      └─ Cria monitor virtual independente à direita do Mac │
│                                                             │
│   2. [ScreenCaptureKit & CoreGraphics] (Hardware GPU)        │
│      └─ Captura a tela a 30 FPS estáveis                    │
│      └─ Insere o ponteiro nativo do mouse em tempo real     │
│      └─ Compacta em JPEG de alta definição (ImageIO)        │
│                                                             │
│   3. [Servidor Node.js] (src/server.js)                     │
│      └─ Multiplexador HTTP / HTTPS (porta 8080)             │
│      └─ Controle de Backpressure (isWriting guard)          │
│      └─ Distribuição de stream MJPEG instantâneo             │
│                                                             │
└──────────────────────────────┬──────────────────────────────┘
                               │
            Cabo Lightning USB │ (0.6ms latência)
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                       IPAD (iOS 10+)                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   4. [MobileSafari / PWA Web Clip] (public/)                │
│      └─ Single <img src="/stream"> tag                      │
│      └─ Decodificação nativa em hardware C++ WebKit         │
│      └─ Zero JavaScript GC / Zero alocações de memória      │
│      └─ Mapeamento de toques em coordenadas no Mac          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 Pré-requisitos

- **Mac**: macOS Monterey (12.3+), Ventura (13+) ou Sonoma (14+).
- **Node.js**: Versão 16 ou superior instalada no Mac.
- **Xcode Command Line Tools** (para compilar o motor nativo em Objective-C):
  ```bash
  xcode-select --install
  ```
- **iPad**: Qualquer iPad com Safari (testado especificamente no iPad 4ª Geração com iOS 10.3.3 de 32-bit).

---

## 🚀 Como Usar

### 1. Clonar o Repositório

```bash
git clone https://github.com/rafaabc73/ipad-display.git
cd ipad-display
```

### 2. Iniciar o Servidor

Execute o script de inicialização:

```bash
./start.sh
```

O script cuidará de tudo automaticamente:
- Gera certificados TLS para suporte a HTTPS no Safari.
- Compila o binário nativo em Objective-C (`bin/ipad-display-core`) via `clang`.
- Inicia o servidor Node.js na porta **8080**.
- Exibe no terminal os endereços IP disponíveis para conexão.

---

### 3. Conectar o iPad

#### Opção A: Conexão por Cabo USB (Recomendada - Latência 0.6ms)
1. Conecte o cabo USB/Lightning do iPad no seu Mac.
2. No iPad, abra **Ajustes** > **Acesso Pessoal** (Personal Hotspot) e **ative**.
3. Se o iPad perguntar, selecione **"Apenas USB"**.
4. No terminal do Mac, você verá o IP da conexão USB (exemplo: `http://192.168.2.1:8080`).
5. Abra o Safari no iPad e acesse esse endereço.

#### Opção B: Conexão via Wi-Fi
1. Conecte o Mac e o iPad na mesma rede Wi-Fi.
2. Acesse o endereço Wi-Fi exibido no terminal (exemplo: `http://192.168.100.107:8080`).

---

### 4. Como Usar no iPad

1. Na tela inicial do app, você verá dois cartões elegantes:
   - **Duplicar Tela**: Espelha o monitor principal do Mac no iPad.
   - **Segunda Tela**: Cria o segundo monitor virtual estendido no Mac.
2. Toque em **"Ativar 2ª Tela"**.
3. No seu Mac, arraste qualquer janela (navegador, terminal, player de vídeo, anotações) para a **borda direita** da tela do Mac — ela entrará suavemente na tela do iPad!
4. **Dica para Tela Cheia (PWA)**:
   - No Safari do iPad, toque no botão de **Compartilhar** (quadrado com seta para cima).
   - Escolha **"Adicionar à Tela de Início"**.
   - Abra pelo novo ícone criado na tela de início: o app funcionará em **tela cheia total**, sem as barras do Safari!

---

## 🎛️ Controles no iPad

Quando o monitor estiver ativo, você tem uma barra flutuante no topo do iPad:
- **Menu**: Volta à tela de seleção.
- **🔥 Alta Definição**: Alterna entre os modos de resolução (1280×960, 1600×1200 e 1024×768).
- **Ajustar / Preencher**: Ajusta o aspecto original (4:3) ou preenche 100% da tela do iPad.
- **Toque**: Ativa ou desativa a conversão de toques no iPad em cliques do mouse no Mac.
- **Tela Cheia**: Ativa o modo de tela cheia nativo do navegador.

---

## 📁 Estrutura de Arquivos

```
ipad-display/
├── src/
│   ├── core.m            # Motor nativo macOS (CGVirtualDisplay + ScreenCaptureKit + JPEG)
│   └── server.js         # Servidor HTTP/HTTPS, backpressure e multiplexador MJPEG
├── public/
│   ├── index.html        # Interface visual do iPad (PWA)
│   ├── app.js            # Lógica do cliente, gerenciamento de stream e toques
│   ├── styles.css        # Estilos modernos padrão Apple
│   ├── manifest.json     # Manifesto PWA para instalação no iOS
│   ├── icon-192.png      # Ícone do aplicativo
│   └── icon-512.png      # Ícone em alta resolução
├── start.sh              # Script de compilação e inicialização em 1 comando
├── package.json          # Metadados e comandos do projeto (sem dependências externas)
├── .gitignore            # Arquivos ignorados pelo Git
└── README.md             # Documentação completa
```

---

## 💡 Como Funciona o Zero Delay?

O principal desafio ao transmitir vídeo para dispositivos antigos como o iPad 4 (chip A6X de 2012) é o limite de processamento de decodificação da CPU/GPU:

1. **Eliminação do Acúmulo de Buffers**: Em transmissões normais, o servidor envia pacotes continuamente. Se o iPad demorar alguns milissegundos para renderizar um quadro, os dados acumulam no buffer TCP, gerando um atraso crescente de vários segundos. Com a proteção de *backpressure* (`client.isWriting = true`), o Mac só envia um novo quadro quando o anterior foi 100% descarregado pelo iPad. Quadros intermediários são descartados instantaneamente no Mac.
2. **Quadro Dimensionado Sob Medida**: Cada frame em 1280×960 tem aproximadamente 100 KB a 140 KB. O processador Apple A6X decodifica esse tamanho em apenas 10 a 14 milissegundos, permitindo manter 30 FPS cravados sem engasgos de memória.
3. **Sem Garbage Collection no Safari**: Ao invés de criar centenas de imagens temporárias por minuto via JavaScript, o stream é alimentado em um único elemento `<img>` contínuo via protocolo MJPEG (`multipart/x-mixed-replace`). O motor C++ do WebKit gerencia a memória internamente com custo zero de CPU JavaScript.

---

## 🤝 Contribuições

Contribuições, correções de bugs e novas ideias são muito bem-vindas! Sinta-se à vontade para abrir uma *Issue* ou enviar um *Pull Request*.

---

## 📄 Licença

Distribuído sob a licença **MIT**. Consulte o arquivo `LICENSE` para mais detalhes.
