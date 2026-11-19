//go:build windows

package main

import (
	"bufio"
	"embed"
	"encoding/binary"
	"fmt"
	"io"
	"io/fs"
	"math"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

//go:embed web/*
var webFS embed.FS

type Client struct {
	conn       net.Conn
	isWS       bool
	transport  uint8
	usbDevID   int
	label      string
	sendMu     sync.Mutex
	closed     atomic.Bool
	inFlight   atomic.Int32
	rttTenthMs atomic.Uint32
}

func (c *Client) Send(h IPD2Header, payload []byte) bool {
	if c.closed.Load() {
		return false
	}
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	if c.closed.Load() {
		return false
	}
	rawHdr := encodeHeader(h)
	var err error
	if c.isWS {
		err = writeWSBinaryFrame(c.conn, rawHdr, payload)
	} else {
		err = writeAll(c.conn, rawHdr[:])
		if err == nil && len(payload) > 0 {
			err = writeAll(c.conn, payload)
		}
	}
	if err != nil {
		c.closed.Store(true)
		c.conn.Close()
		return false
	}
	return true
}

type Server struct {
	hostName   string
	capturer   *WinCapturer
	usbWatcher *USBMuxWatcher

	mu         sync.Mutex
	clients    map[*Client]bool
	mode       uint8
	preset     uint8
	activeRect winRect
	fbW, fbH   int
	hasSecond  bool
	forceSync  atomic.Bool
	seq        atomic.Uint32
	fps        atomic.Uint32
}

func NewServer() *Server {
	name, _ := os.Hostname()
	if name == "" {
		name = "Windows PC"
	}
	s := &Server{
		hostName: name,
		capturer: NewWinCapturer(),
		clients:  make(map[*Client]bool),
		mode:     ModeIdle,
		preset:   PresetRetina,
	}
	s.usbWatcher = NewUSBMuxWatcher(TCPPort, func(conn net.Conn, devID int) {
		s.registerClient(conn, false, TransportUSB, devID, fmt.Sprintf("USB:%d", devID))
	})
	return s
}

func (s *Server) selectMonitor(mode uint8) (winRect, bool) {
	mons := listMonitors()
	if len(mons) == 0 {
		return winRect{0, 0, 1920, 1080}, false
	}
	primary := mons[0]
	var secondary *MonitorDesc
	for i := range mons {
		if mons[i].IsPrimary {
			primary = mons[i]
		} else if secondary == nil {
			m := mons[i]
			secondary = &m
		}
	}
	if mode == ModeSecond && secondary != nil {
		return secondary.Rect, true
	}
	return primary.Rect, secondary != nil
}

func (s *Server) setMode(mode, preset uint8) {
	s.mu.Lock()
	s.mode = mode
	s.preset = preset
	if mode == ModeIdle {
		s.fbW, s.fbH = 0, 0
		s.mu.Unlock()
		s.broadcastDisplayInfo()
		return
	}
	rect, hasSec := s.selectMonitor(mode)
	s.activeRect = rect
	s.hasSecond = hasSec
	if mode == ModeSecond && !hasSec {
		fmt.Println("[Windows] Aviso: Nenhum 2º monitor virtual detectado — execute install_windows_vdd.bat para ativar 2ª tela estendida (usando monitor principal por enquanto).")
	}
	w, h := s.capturer.Configure(rect, preset)
	s.fbW, s.fbH = w, h
	s.forceSync.Store(true)
	s.mu.Unlock()
	fmt.Printf("[Windows] Modo=%d Preset=%d | Captura=%dx%d\n", mode, preset, w, h)
	s.broadcastDisplayInfo()
}

func (s *Server) broadcastDisplayInfo() {
	s.mu.Lock()
	mode, preset, fbW, fbH := s.mode, s.preset, uint16(s.fbW), uint16(s.fbH)
	logW := uint16(s.activeRect.Right - s.activeRect.Left)
	logH := uint16(s.activeRect.Bottom - s.activeRect.Top)
	hasVD := uint8(0)
	if s.hasSecond {
		hasVD = 1
	}
	clients := make([]*Client, 0, len(s.clients))
	for c := range s.clients {
		clients = append(clients, c)
	}
	s.mu.Unlock()

	fps := uint16(s.fps.Load())
	for _, c := range clients {
		payload := encodeDisplayInfo(mode, preset, c.transport, fbW, fbH, logW, logH, fps, uint16(c.rttTenthMs.Load()), hasVD, s.hostName)
		c.Send(IPD2Header{Type: MsgDisplayInfo, PayloadLen: uint32(len(payload))}, payload)
	}
}

func (s *Server) registerClient(conn net.Conn, isWS bool, transport uint8, usbDevID int, label string) {
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
	c := &Client{conn: conn, isWS: isWS, transport: transport, usbDevID: usbDevID, label: label}
	if transport == TransportUSB {
		c.rttTenthMs.Store(10)
	} else {
		c.rttTenthMs.Store(50)
	}

	s.mu.Lock()
	s.clients[c] = true
	s.mu.Unlock()
	fmt.Printf("[Servidor] iPad conectado: %s\n", label)
	s.broadcastDisplayInfo()
	s.forceSync.Store(true)

	go func() {
		defer func() {
			c.closed.Store(true)
			conn.Close()
			s.mu.Lock()
			delete(s.clients, c)
			rem := len(s.clients)
			s.mu.Unlock()
			fmt.Printf("[Servidor] iPad desconectado: %s (restantes: %d)\n", label, rem)
			if usbDevID > 0 {
				s.usbWatcher.NotifyClosed(usbDevID)
			}
			if rem == 0 {
				s.setMode(ModeIdle, s.preset)
			}
		}()

		if isWS {
			for {
				op, data, err := readWSFrame(conn)
				if err != nil || op == 0x08 {
					return
				}
				if len(data) >= 16 {
					if hdr, ok := decodeHeader(data[:16]); ok && len(data) >= 16+int(hdr.PayloadLen) {
						s.handlePacket(c, hdr, data[16:16+hdr.PayloadLen])
					}
				}
			}
		} else {
			var hbuf [16]byte
			for {
				if _, err := io.ReadFull(conn, hbuf[:]); err != nil {
					return
				}
				hdr, ok := decodeHeader(hbuf[:])
				if !ok || hdr.PayloadLen > 1024*1024 {
					return
				}
				var payload []byte
				if hdr.PayloadLen > 0 {
					payload = make([]byte, hdr.PayloadLen)
					if _, err := io.ReadFull(conn, payload); err != nil {
						return
					}
				}
				s.handlePacket(c, hdr, payload)
			}
		}
	}()
}

func (s *Server) handlePacket(c *Client, hdr IPD2Header, payload []byte) {
	switch hdr.Type {
	case MsgHello:
		s.broadcastDisplayInfo()
		s.forceSync.Store(true)
	case MsgControl:
		if len(payload) >= 2 {
			cmd, arg1 := payload[0], payload[1]
			s.mu.Lock()
			m, p := s.mode, s.preset
			s.mu.Unlock()
			switch cmd {
			case CtrlSetMode:
				s.setMode(arg1, p)
			case CtrlSetPreset:
				if m != ModeIdle {
					s.setMode(m, arg1)
				} else {
					s.mu.Lock()
					s.preset = arg1
					s.mu.Unlock()
				}
			case CtrlRequestSync:
				s.forceSync.Store(true)
			}
		}
	case MsgInput:
		s.mu.Lock()
		rect := s.activeRect
		s.mu.Unlock()
		injectWinInput(rect, payload)
	case MsgPing:
		c.Send(IPD2Header{Type: MsgPong, Seq: hdr.Seq, PayloadLen: uint32(len(payload))}, payload)
	case MsgPong:
		if len(payload) >= 8 {
			sentUs := binary.LittleEndian.Uint64(payload[:8])
			nowUs := uint64(time.Now().UnixMicro())
			if nowUs >= sentUs {
				tenth := uint32((nowUs - sentUs) / 100)
				if tenth < 1 {
					tenth = 1
				}
				c.rttTenthMs.Store(tenth)
			}
		}
	case MsgFrameAck:
		if c.inFlight.Load() > 0 {
			c.inFlight.Add(-1)
		}
	}
}

func (s *Server) captureLoop() {
	ticker := time.NewTicker(16 * time.Millisecond) // ~60 FPS
	defer ticker.Stop()

	var frames uint32
	lastFpsT := time.Now()
	var lastMotion time.Time
	needsSharpen := false

	for range ticker.C {
		s.mu.Lock()
		mode := s.mode
		nClients := len(s.clients)
		clients := make([]*Client, 0, nClients)
		for c := range s.clients {
			clients = append(clients, c)
		}
		if mode == ModeIdle || nClients == 0 {
			s.mu.Unlock()
			continue
		}

		frame := s.capturer.GrabFrame()
		if frame == nil {
			s.mu.Unlock()
			continue
		}

		force := s.forceSync.Swap(false)
		if !force && needsSharpen && time.Since(lastMotion) >= 110*time.Millisecond {
			force = true
			needsSharpen = false
		}

		batches, counts, flags, heavy := s.capturer.DiffAndEncode(frame, force)
		s.mu.Unlock()

		if heavy {
			needsSharpen = true
			lastMotion = time.Now()
		}
		if len(batches) == 0 {
			continue
		}

		frames++
		if time.Since(lastFpsT) >= time.Second {
			s.fps.Store(frames)
			frames = 0
			lastFpsT = time.Now()
		}

		for idx, b := range batches {
			isMotion := (flags[idx] & TileFlagHalfRes) != 0
			seq := s.seq.Add(1)
			hdr := IPD2Header{
				Type:       MsgTileBatch,
				Flags:      flags[idx],
				Extra:      counts[idx],
				Seq:        seq,
				PayloadLen: uint32(len(b)),
			}
			for _, c := range clients {
				if isMotion && c.inFlight.Load() >= 2 {
					continue
				}
				if isMotion {
					c.inFlight.Add(1)
				}
				c.Send(hdr, b)
			}
		}
	}
}

func (s *Server) cursorLoop() {
	ticker := time.NewTicker(16 * time.Millisecond)
	defer ticker.Stop()
	var lastX, lastY float32 = -1, -1
	var lastVis uint8 = 2

	for range ticker.C {
		s.mu.Lock()
		mode := s.mode
		rect := s.activeRect
		clients := make([]*Client, 0, len(s.clients))
		for c := range s.clients {
			clients = append(clients, c)
		}
		s.mu.Unlock()
		if mode == ModeIdle || len(clients) == 0 {
			continue
		}
		nx, ny, vis := getCursorNormalized(rect)
		if vis != lastVis || (vis == 1 && (math.Abs(float64(nx-lastX)) > 0.0002 || math.Abs(float64(ny-lastY)) > 0.0002)) {
			lastX, lastY, lastVis = nx, ny, vis
			payload := encodeCursor(nx, ny, vis)
			hdr := IPD2Header{Type: MsgCursor, PayloadLen: uint32(len(payload))}
			for _, c := range clients {
				c.Send(hdr, payload)
			}
		}
	}
}

func (s *Server) pingLoop() {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		var p [8]byte
		binary.LittleEndian.PutUint64(p[:], uint64(time.Now().UnixMicro()))
		s.mu.Lock()
		clients := make([]*Client, 0, len(s.clients))
		for c := range s.clients {
			clients = append(clients, c)
		}
		s.mu.Unlock()
		for _, c := range clients {
			c.Send(IPD2Header{Type: MsgPing, PayloadLen: 8}, p[:])
		}
		s.broadcastDisplayInfo()
	}
}

func mimeFor(p string) string {
	switch strings.ToLower(filepath.Ext(p)) {
	case ".html":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js":
		return "application/javascript; charset=utf-8"
	case ".json":
		return "application/json; charset=utf-8"
	case ".png":
		return "image/png"
	default:
		return "application/octet-stream"
	}
}

func (s *Server) handleHTTP(conn net.Conn) {
	br := bufio.NewReader(conn)
	reqLine, err := br.ReadString('\n')
	if err != nil {
		conn.Close()
		return
	}
	parts := strings.Split(strings.TrimSpace(reqLine), " ")
	if len(parts) < 2 {
		conn.Close()
		return
	}
	reqPath := strings.SplitN(parts[1], "?", 2)[0]

	headers := map[string]string{}
	for {
		line, err := br.ReadString('\n')
		if err != nil || strings.TrimSpace(line) == "" {
			break
		}
		if idx := strings.IndexByte(line, ':'); idx > 0 {
			k := strings.ToLower(strings.TrimSpace(line[:idx]))
			v := strings.TrimSpace(line[idx+1:])
			headers[k] = v
		}
	}

	if reqPath == "/ws" && strings.EqualFold(headers["upgrade"], "websocket") && headers["sec-websocket-key"] != "" {
		accept := wsAcceptKey(headers["sec-websocket-key"])
		resp := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"
		if err := writeAll(conn, []byte(resp)); err != nil {
			conn.Close()
			return
		}
		s.registerClient(conn, true, TransportWiFi, 0, conn.RemoteAddr().String())
		return
	}

	defer conn.Close()
	if reqPath == "/" {
		reqPath = "/index.html"
	}
	clean := strings.TrimPrefix(reqPath, "/")
	if strings.Contains(clean, "..") {
		return
	}
	data, err := fs.ReadFile(webFS, "web/"+clean)
	if err != nil {
		writeAll(conn, []byte("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found"))
		return
	}
	hdr := fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", mimeFor(clean), len(data))
	writeAll(conn, []byte(hdr))
	writeAll(conn, data)
}

func printBanner() {
	fmt.Println("=================================================================")
	fmt.Println("   iPad Display Pro v2.0 — Windows Host (USB + Wi-Fi Retina)")
	fmt.Println("=================================================================")
	fmt.Println("  [USB] App Nativo iOS via Cabo Lightning (usbmuxd :27015): ATIVO")
	fmt.Printf("  [TCP] App Nativo iOS via Wi-Fi: porta %d\n", TCPPort)
	fmt.Println("  [WEB] App Web / PWA Retina (Safari no iPad):")
	ifaces, _ := net.Interfaces()
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok && ipnet.IP.To4() != nil {
				ip := ipnet.IP.String()
				if !strings.HasPrefix(ip, "169.254.") {
					fmt.Printf("        http://%s:%d\n", ip, HTTPPort)
				}
			}
		}
	}
	fmt.Println("=================================================================")
}

func main() {
	initPlatformDPI()
	srv := NewServer()
	srv.usbWatcher.Start()

	go srv.captureLoop()
	go srv.cursorLoop()
	go srv.pingLoop()

	tcpLn, err := net.Listen("tcp", fmt.Sprintf(":%d", TCPPort))
	if err == nil {
		go func() {
			for {
				c, err := tcpLn.Accept()
				if err == nil {
					srv.registerClient(c, false, TransportWiFi, 0, c.RemoteAddr().String())
				}
			}
		}()
	}

	httpLn, err := net.Listen("tcp", fmt.Sprintf(":%d", HTTPPort))
	if err != nil {
		fmt.Printf("Erro ao abrir porta %d: %v\n", HTTPPort, err)
		os.Exit(1)
	}

	printBanner()
	for {
		c, err := httpLn.Accept()
		if err == nil {
			go srv.handleHTTP(c)
		}
	}
}
