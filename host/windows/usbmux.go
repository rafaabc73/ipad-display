package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Windows usbmuxd runs on TCP 127.0.0.1:27015 (provided by Apple Mobile Device Support / iTunes)
const winUSBMuxAddr = "127.0.0.1:27015"

type USBMuxWatcher struct {
	targetPort uint16
	onConnect  func(conn net.Conn, deviceID int)
	mu         sync.Mutex
	attached   map[int]bool
	connected  map[int]bool
}

func NewUSBMuxWatcher(targetPort uint16, onConnect func(conn net.Conn, deviceID int)) *USBMuxWatcher {
	return &USBMuxWatcher{
		targetPort: targetPort,
		onConnect:  onConnect,
		attached:   make(map[int]bool),
		connected:  make(map[int]bool),
	}
}

func (u *USBMuxWatcher) NotifyClosed(deviceID int) {
	u.mu.Lock()
	delete(u.connected, deviceID)
	stillAttached := u.attached[deviceID]
	u.mu.Unlock()
	if stillAttached {
		go u.connectLoop(deviceID)
	}
}

func (u *USBMuxWatcher) Start() {
	go u.listenLoop()
}

func sendMuxPlist(conn net.Conn, xmlBody string, tag uint32) error {
	payload := []byte(xmlBody)
	var hdr [16]byte
	binary.LittleEndian.PutUint32(hdr[0:4], uint32(16+len(payload)))
	binary.LittleEndian.PutUint32(hdr[4:8], 1)
	binary.LittleEndian.PutUint32(hdr[8:12], 8)
	binary.LittleEndian.PutUint32(hdr[12:16], tag)
	if err := writeAll(conn, hdr[:]); err != nil {
		return err
	}
	return writeAll(conn, payload)
}

func recvMuxPlist(conn net.Conn) (string, error) {
	var hdr [16]byte
	if _, err := io.ReadFull(conn, hdr[:]); err != nil {
		return "", err
	}
	length := binary.LittleEndian.Uint32(hdr[0:4])
	if length < 16 || length > 2*1024*1024 {
		return "", fmt.Errorf("invalid usbmux length %d", length)
	}
	buf := make([]byte, length-16)
	if _, err := io.ReadFull(conn, buf); err != nil {
		return "", err
	}
	return string(buf), nil
}

var reDeviceID = regexp.MustCompile(`<key>DeviceID</key>\s*<integer>(\d+)</integer>`)
var reResultNum = regexp.MustCompile(`<key>Number</key>\s*<integer>(\d+)</integer>`)

func (u *USBMuxWatcher) listenLoop() {
	listenXML := `<?xml version="1.0" encoding="UTF-8"?>` +
		`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` +
		`<plist version="1.0"><dict><key>MessageType</key><string>Listen</string>` +
		`<key>ClientVersionString</key><string>iPadDisplay-2.0</string>` +
		`<key>ProgName</key><string>iPadDisplay</string></dict></plist>`

	for {
		conn, err := net.DialTimeout("tcp", winUSBMuxAddr, 2*time.Second)
		if err != nil {
			time.Sleep(2 * time.Second)
			continue
		}
		if err := sendMuxPlist(conn, listenXML, 1); err != nil {
			conn.Close()
			time.Sleep(2 * time.Second)
			continue
		}
		// Read initial Listen Result
		if _, err := recvMuxPlist(conn); err != nil {
			conn.Close()
			time.Sleep(2 * time.Second)
			continue
		}
		fmt.Println("[USBMux] Monitorando cabo USB do iPad via Apple Mobile Device Support (porta 27015)...")

		for {
			msg, err := recvMuxPlist(conn)
			if err != nil {
				break
			}
			m := reDeviceID.FindStringSubmatch(msg)
			if len(m) < 2 {
				continue
			}
			devID, _ := strconv.Atoi(m[1])
			if strings.Contains(msg, "<string>Attached</string>") {
				if strings.Contains(msg, "<key>ConnectionType</key>") && !strings.Contains(msg, "<string>USB</string>") {
					continue
				}
				u.mu.Lock()
				u.attached[devID] = true
				already := u.connected[devID]
				u.mu.Unlock()
				fmt.Printf("[USBMux] iPad detectado no cabo USB (DeviceID=%d)\n", devID)
				if !already {
					go u.connectLoop(devID)
				}
			} else if strings.Contains(msg, "<string>Detached</string>") {
				u.mu.Lock()
				delete(u.attached, devID)
				delete(u.connected, devID)
				u.mu.Unlock()
				fmt.Printf("[USBMux] Cabo USB desconectado (DeviceID=%d)\n", devID)
			}
		}
		conn.Close()
		time.Sleep(2 * time.Second)
	}
}

func (u *USBMuxWatcher) connectLoop(deviceID int) {
	// PortNumber must be network byte order (big-endian)
	portNet := ((u.targetPort & 0xFF) << 8) | (u.targetPort >> 8)
	connectXML := fmt.Sprintf(
		`<?xml version="1.0" encoding="UTF-8"?>`+
			`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">`+
			`<plist version="1.0"><dict><key>MessageType</key><string>Connect</string>`+
			`<key>DeviceID</key><integer>%d</integer><key>PortNumber</key><integer>%d</integer>`+
			`<key>ClientVersionString</key><string>iPadDisplay-2.0</string>`+
			`<key>ProgName</key><string>iPadDisplay</string></dict></plist>`,
		deviceID, portNet,
	)

	for {
		u.mu.Lock()
		ok := u.attached[deviceID] && !u.connected[deviceID]
		u.mu.Unlock()
		if !ok {
			return
		}

		conn, err := net.DialTimeout("tcp", winUSBMuxAddr, 2*time.Second)
		if err != nil {
			time.Sleep(1 * time.Second)
			continue
		}
		if err := sendMuxPlist(conn, connectXML, 2); err == nil {
			if reply, err := recvMuxPlist(conn); err == nil {
				m := reResultNum.FindStringSubmatch(reply)
				if len(m) >= 2 && m[1] == "0" {
					u.mu.Lock()
					if u.attached[deviceID] && !u.connected[deviceID] {
						u.connected[deviceID] = true
						u.mu.Unlock()
						fmt.Printf("[USBMux] Túnel USB conectado ao app do iPad (DeviceID=%d)!\n", deviceID)
						u.onConnect(conn, deviceID)
						return
					}
					u.mu.Unlock()
				}
			}
		}
		conn.Close()
		time.Sleep(800 * time.Millisecond)
	}
}
