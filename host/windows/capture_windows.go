//go:build windows

package main

import (
	"bytes"
	"encoding/binary"
	"math"
	"syscall"
	"unsafe"
)

var (
	user32                 = syscall.NewLazyDLL("user32.dll")
	gdi32                  = syscall.NewLazyDLL("gdi32.dll")
	procSetProcessDPIAware = user32.NewProc("SetProcessDPIAware")
	procEnumDisplayMons    = user32.NewProc("EnumDisplayMonitors")
	procGetMonitorInfoW    = user32.NewProc("GetMonitorInfoW")
	procGetDC              = user32.NewProc("GetDC")
	procReleaseDC          = user32.NewProc("ReleaseDC")
	procGetCursorPos       = user32.NewProc("GetCursorPos")
	procSendInput          = user32.NewProc("SendInput")
	procGetSystemMetrics   = user32.NewProc("GetSystemMetrics")

	procCreateCompatibleDC = gdi32.NewProc("CreateCompatibleDC")
	procDeleteDC           = gdi32.NewProc("DeleteDC")
	procCreateDIBSection   = gdi32.NewProc("CreateDIBSection")
	procSelectObject       = gdi32.NewProc("SelectObject")
	procDeleteObject       = gdi32.NewProc("DeleteObject")
	procBitBlt             = gdi32.NewProc("BitBlt")
	procStretchBlt         = gdi32.NewProc("StretchBlt")
	procSetStretchBltMode  = gdi32.NewProc("SetStretchBltMode")
)

const (
	srccopy          = 0x00CC0020
	halftoneMode     = 4
	dibRGBColors     = 0
	biRGB            = 0
	monitorPrimary   = 1
	smXVirtualScreen = 76
	smYVirtualScreen = 77
	smCXVirtualScr   = 78
	smCYVirtualScr   = 79

	inputMouse     = 0
	inputKeyboard  = 1
	mouseMove      = 0x0001
	mouseLeftDown  = 0x0002
	mouseLeftUp    = 0x0004
	mouseRightDown = 0x0008
	mouseRightUp   = 0x0010
	mouseWheel     = 0x0800
	mouseHWheel    = 0x01000
	mouseVirtual   = 0x4000
	mouseAbsolute  = 0x8000
	keyEventKeyUp  = 0x0002
	keyEventUni    = 0x0004
)

type winRect struct {
	Left, Top, Right, Bottom int32
}

type winPoint struct {
	X, Y int32
}

type monitorInfo struct {
	CbSize    uint32
	RcMonitor winRect
	RcWork    winRect
	DwFlags   uint32
}

type bitmapInfoHeader struct {
	BiSize          uint32
	BiWidth         int32
	BiHeight        int32
	BiPlanes        uint16
	BiBitCount      uint16
	BiCompression   uint32
	BiSizeImage     uint32
	BiXPelsPerMeter int32
	BiYPelsPerMeter int32
	BiClrUsed       uint32
	BiClrImportant  uint32
}

type bitmapInfo struct {
	Header bitmapInfoHeader
	Colors [1]uint32
}

type mouseInput struct {
	Dx, Dy      int32
	MouseData   uint32
	DwFlags     uint32
	Time        uint32
	DwExtraInfo uintptr
}

type keybdInput struct {
	WVk         uint16
	WScan       uint16
	DwFlags     uint32
	Time        uint32
	DwExtraInfo uintptr
}

type inputUnion struct {
	Type uint32
	_    uint32 // 64-bit alignment padding before union
	Mi   mouseInput
}

type keyInputUnion struct {
	Type uint32
	_    uint32
	Ki   keybdInput
	_    [8]byte // Match sizeof(INPUT) = 40 on amd64
}

type MonitorDesc struct {
	Rect      winRect
	IsPrimary bool
}

func initPlatformDPI() {
	procSetProcessDPIAware.Call()
}

func listMonitors() []MonitorDesc {
	var mons []MonitorDesc
	cb := syscall.NewCallback(func(hMon, hdc uintptr, lprc *winRect, lparam uintptr) uintptr {
		var mi monitorInfo
		mi.CbSize = uint32(unsafe.Sizeof(mi))
		r, _, _ := procGetMonitorInfoW.Call(hMon, uintptr(unsafe.Pointer(&mi)))
		if r != 0 {
			mons = append(mons, MonitorDesc{
				Rect:      mi.RcMonitor,
				IsPrimary: (mi.DwFlags & monitorPrimary) != 0,
			})
		}
		return 1
	})
	procEnumDisplayMons.Call(0, 0, cb, 0)
	return mons
}

type WinCapturer struct {
	screenDC  uintptr
	memDC     uintptr
	hbmp      uintptr
	oldObj    uintptr
	bitsPtr   unsafe.Pointer
	outW      int
	outH      int
	srcRect   winRect
	prevFrame []byte
	tileBuf   []byte
	lz4Buf    []byte
	rgb565Buf []byte
}

func NewWinCapturer() *WinCapturer {
	return &WinCapturer{
		tileBuf: make([]byte, 128*128*4),
		lz4Buf:  make([]byte, 2048*1536*2+65536),
	}
}

func (c *WinCapturer) Close() {
	if c.memDC != 0 {
		if c.oldObj != 0 {
			procSelectObject.Call(c.memDC, c.oldObj)
			c.oldObj = 0
		}
		if c.hbmp != 0 {
			procDeleteObject.Call(c.hbmp)
			c.hbmp = 0
		}
		procDeleteDC.Call(c.memDC)
		c.memDC = 0
	}
	if c.screenDC != 0 {
		procReleaseDC.Call(0, c.screenDC)
		c.screenDC = 0
	}
}

func (c *WinCapturer) Configure(src winRect, preset uint8) (int, int) {
	c.Close()
	c.srcRect = src
	sw := int(src.Right - src.Left)
	sh := int(src.Bottom - src.Top)
	if sw <= 0 || sh <= 0 {
		sw, sh = 1920, 1080
	}

	maxW, maxH := 2048, 1536
	if preset == PresetSmooth {
		maxW, maxH = 1024, 768
	}

	outW, outH := sw, sh
	if outW > maxW || outH > maxH {
		aspect := float64(sw) / float64(sh)
		if float64(maxW)/float64(maxH) > aspect {
			outH = maxH
			outW = int(float64(outH) * aspect)
		} else {
			outW = maxW
			outH = int(float64(outW) / aspect)
		}
	}
	outW = (outW + 7) &^ 7
	outH = (outH + 7) &^ 7
	if outW < 320 {
		outW = 320
	}
	if outH < 240 {
		outH = 240
	}

	c.outW = outW
	c.outH = outH

	c.screenDC, _, _ = procGetDC.Call(0)
	c.memDC, _, _ = procCreateCompatibleDC.Call(c.screenDC)

	var bi bitmapInfo
	bi.Header.BiSize = uint32(unsafe.Sizeof(bi.Header))
	bi.Header.BiWidth = int32(outW)
	bi.Header.BiHeight = -int32(outH) // Top-down BGRA
	bi.Header.BiPlanes = 1
	bi.Header.BiBitCount = 32
	bi.Header.BiCompression = biRGB

	c.hbmp, _, _ = procCreateDIBSection.Call(
		c.memDC,
		uintptr(unsafe.Pointer(&bi)),
		dibRGBColors,
		uintptr(unsafe.Pointer(&c.bitsPtr)),
		0, 0,
	)
	c.oldObj, _, _ = procSelectObject.Call(c.memDC, c.hbmp)
	procSetStretchBltMode.Call(c.memDC, halftoneMode)

	c.prevFrame = make([]byte, outW*outH*4)
	c.rgb565Buf = make([]byte, (outW/2)*(outH/2)*2)
	return outW, outH
}

func (c *WinCapturer) GrabFrame() []byte {
	if c.bitsPtr == nil || c.outW <= 0 || c.outH <= 0 {
		return nil
	}
	sw := int(c.srcRect.Right - c.srcRect.Left)
	sh := int(c.srcRect.Bottom - c.srcRect.Top)
	if sw == c.outW && sh == c.outH {
		procBitBlt.Call(c.memDC, 0, 0, uintptr(c.outW), uintptr(c.outH),
			c.screenDC, uintptr(c.srcRect.Left), uintptr(c.srcRect.Top), srccopy)
	} else {
		procStretchBlt.Call(c.memDC, 0, 0, uintptr(c.outW), uintptr(c.outH),
			c.screenDC, uintptr(c.srcRect.Left), uintptr(c.srcRect.Top),
			uintptr(sw), uintptr(sh), srccopy)
	}
	n := c.outW * c.outH * 4
	return unsafe.Slice((*byte)(c.bitsPtr), n)
}

func (c *WinCapturer) DiffAndEncode(frame []byte, forceFull bool) (batches [][]byte, counts []uint16, flags []uint8, heavyMotion bool) {
	const tileSize = 128
	w, h := c.outW, c.outH
	cols := (w + tileSize - 1) / tileSize
	rows := (h + tileSize - 1) / tileSize
	totalTiles := cols * rows
	dirty := make([]bool, totalTiles)
	changed := 0

	if forceFull {
		for i := range dirty {
			dirty[i] = true
		}
		changed = totalTiles
	} else {
		for ty := 0; ty < rows; ty++ {
			py := ty * tileSize
			th := tileSize
			if h-py < th {
				th = h - py
			}
			for tx := 0; tx < cols; tx++ {
				px := tx * tileSize
				tw := tileSize
				if w-px < tw {
					tw = w - px
				}
				rowBytes := tw * 4
				diff := false
				for row := 0; row < th; row++ {
					off := ((py+row)*w + px) * 4
					if !bytes.Equal(frame[off:off+rowBytes], c.prevFrame[off:off+rowBytes]) {
						diff = true
						break
					}
				}
				if diff {
					dirty[ty*cols+tx] = true
					changed++
				}
			}
		}
	}

	if changed == 0 {
		return nil, nil, nil, false
	}

	// Fast motion half-res RGB565 when >40% screen changed and not forcing lossless sync
	if !forceFull && changed > (totalTiles*40)/100 && w >= 512 && h >= 512 {
		hw, hh := w/2, h/2
		dst := c.rgb565Buf[:hw*hh*2]
		di := 0
		for y := 0; y < hh; y++ {
			rowOff := (y * 2) * w * 4
			for x := 0; x < hw; x++ {
				p := rowOff + (x*2)*4
				b := uint16(frame[p]) >> 3
				g := uint16(frame[p+1]) >> 2
				r := uint16(frame[p+2]) >> 3
				v := (r << 11) | (g << 5) | b
				dst[di] = byte(v)
				dst[di+1] = byte(v >> 8)
				di += 2
			}
		}
		compLen := lz4CompressBlock(dst, c.lz4Buf)
		var out bytes.Buffer
		var bh [4]byte
		binary.LittleEndian.PutUint16(bh[0:2], uint16(hw))
		binary.LittleEndian.PutUint16(bh[2:4], uint16(hh))
		out.Write(bh[:])
		var thdr [14]byte
		binary.LittleEndian.PutUint16(thdr[4:6], uint16(hw))
		binary.LittleEndian.PutUint16(thdr[6:8], uint16(hh))
		if compLen > 0 && compLen < len(dst) {
			thdr[8] = EncLZ4RGB565
			binary.LittleEndian.PutUint32(thdr[10:14], uint32(compLen))
			out.Write(thdr[:])
			out.Write(c.lz4Buf[:compLen])
		} else {
			thdr[8] = EncRawRGB565
			binary.LittleEndian.PutUint32(thdr[10:14], uint32(len(dst)))
			out.Write(thdr[:])
			out.Write(dst)
		}
		return [][]byte{out.Bytes()}, []uint16{1}, []uint8{TileFlagHalfRes}, true
	}

	// Lossless Retina LZ4 BGRA tiles
	var batch bytes.Buffer
	writeHeader := func() {
		batch.Reset()
		var bh [4]byte
		binary.LittleEndian.PutUint16(bh[0:2], uint16(w))
		binary.LittleEndian.PutUint16(bh[2:4], uint16(h))
		batch.Write(bh[:])
	}
	writeHeader()
	count := uint16(0)
	fl := uint8(0)
	if forceFull {
		fl = TileFlagFullSync
	}

	for ty := 0; ty < rows; ty++ {
		py := ty * tileSize
		th := tileSize
		if h-py < th {
			th = h - py
		}
		for tx := 0; tx < cols; tx++ {
			if !dirty[ty*cols+tx] {
				continue
			}
			px := tx * tileSize
			tw := tileSize
			if w-px < tw {
				tw = w - px
			}
			rowBytes := tw * 4
			rawBytes := tw * th * 4
			for row := 0; row < th; row++ {
				off := ((py+row)*w + px) * 4
				copy(c.prevFrame[off:off+rowBytes], frame[off:off+rowBytes])
				copy(c.tileBuf[row*rowBytes:(row+1)*rowBytes], frame[off:off+rowBytes])
			}
			compLen := lz4CompressBlock(c.tileBuf[:rawBytes], c.lz4Buf)
			var thdr [14]byte
			binary.LittleEndian.PutUint16(thdr[0:2], uint16(px))
			binary.LittleEndian.PutUint16(thdr[2:4], uint16(py))
			binary.LittleEndian.PutUint16(thdr[4:6], uint16(tw))
			binary.LittleEndian.PutUint16(thdr[6:8], uint16(th))
			if compLen > 0 && compLen < rawBytes {
				thdr[8] = EncLZ4BGRA
				binary.LittleEndian.PutUint32(thdr[10:14], uint32(compLen))
				batch.Write(thdr[:])
				batch.Write(c.lz4Buf[:compLen])
			} else {
				thdr[8] = EncRawBGRA
				binary.LittleEndian.PutUint32(thdr[10:14], uint32(rawBytes))
				batch.Write(thdr[:])
				batch.Write(c.tileBuf[:rawBytes])
			}
			count++
			if count >= 32 {
				cp := make([]byte, batch.Len())
				copy(cp, batch.Bytes())
				batches = append(batches, cp)
				counts = append(counts, count)
				flags = append(flags, fl)
				writeHeader()
				count = 0
			}
		}
	}
	if count > 0 {
		cp := make([]byte, batch.Len())
		copy(cp, batch.Bytes())
		batches = append(batches, cp)
		counts = append(counts, count)
		flags = append(flags, fl)
	}
	return batches, counts, flags, false
}

func getCursorNormalized(rect winRect) (float32, float32, uint8) {
	var pt winPoint
	r, _, _ := procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	if r == 0 {
		return 0, 0, 0
	}
	if pt.X < rect.Left || pt.X >= rect.Right || pt.Y < rect.Top || pt.Y >= rect.Bottom {
		return 0, 0, 0
	}
	w := float32(rect.Right - rect.Left)
	h := float32(rect.Bottom - rect.Top)
	if w <= 0 || h <= 0 {
		return 0, 0, 0
	}
	return float32(pt.X-rect.Left) / w, float32(pt.Y-rect.Top) / h, 1
}

func injectWinInput(rect winRect, payload []byte) {
	if len(payload) < 20 {
		return
	}
	evType := payload[0]
	nx := math.Float32frombits(binary.LittleEndian.Uint32(payload[4:8]))
	ny := math.Float32frombits(binary.LittleEndian.Uint32(payload[8:12]))
	keyData := binary.LittleEndian.Uint32(payload[12:16])

	vx, _, _ := procGetSystemMetrics.Call(smXVirtualScreen)
	vy, _, _ := procGetSystemMetrics.Call(smYVirtualScreen)
	vw, _, _ := procGetSystemMetrics.Call(smCXVirtualScr)
	vh, _, _ := procGetSystemMetrics.Call(smCYVirtualScr)
	if vw == 0 {
		vw = 1920
	}
	if vh == 0 {
		vh = 1080
	}

	absCoords := func(fx, fy float32) (int32, int32) {
		if fx < 0 {
			fx = 0
		} else if fx > 1 {
			fx = 1
		}
		if fy < 0 {
			fy = 0
		} else if fy > 1 {
			fy = 1
		}
		px := float64(rect.Left) + float64(fx)*float64(rect.Right-rect.Left)
		py := float64(rect.Top) + float64(fy)*float64(rect.Bottom-rect.Top)
		ax := int32(((px - float64(int32(vx))) * 65535.0) / float64(vw))
		ay := int32(((py - float64(int32(vy))) * 65535.0) / float64(vh))
		return ax, ay
	}

	sendMouse := func(flags uint32, dx, dy int32, data uint32) {
		var inp inputUnion
		inp.Type = inputMouse
		inp.Mi = mouseInput{Dx: dx, Dy: dy, MouseData: data, DwFlags: flags}
		procSendInput.Call(1, uintptr(unsafe.Pointer(&inp)), unsafe.Sizeof(inp))
	}

	switch evType {
	case InputMove, InputLeftDrag:
		ax, ay := absCoords(nx, ny)
		sendMouse(mouseMove|mouseAbsolute|mouseVirtual, ax, ay, 0)
	case InputLeftDown:
		ax, ay := absCoords(nx, ny)
		sendMouse(mouseMove|mouseAbsolute|mouseVirtual|mouseLeftDown, ax, ay, 0)
	case InputLeftUp:
		ax, ay := absCoords(nx, ny)
		sendMouse(mouseMove|mouseAbsolute|mouseVirtual|mouseLeftUp, ax, ay, 0)
	case InputDoubleClick:
		ax, ay := absCoords(nx, ny)
		sendMouse(mouseMove|mouseAbsolute|mouseVirtual|mouseLeftDown, ax, ay, 0)
		sendMouse(mouseMove|mouseAbsolute|mouseVirtual|mouseLeftUp, ax, ay, 0)
		sendMouse(mouseMove|mouseAbsolute|mouseVirtual|mouseLeftDown, ax, ay, 0)
		sendMouse(mouseMove|mouseAbsolute|mouseVirtual|mouseLeftUp, ax, ay, 0)
	case InputRightDown:
		ax, ay := absCoords(nx, ny)
		sendMouse(mouseMove|mouseAbsolute|mouseVirtual|mouseRightDown, ax, ay, 0)
	case InputRightUp:
		ax, ay := absCoords(nx, ny)
		sendMouse(mouseMove|mouseAbsolute|mouseVirtual|mouseRightUp, ax, ay, 0)
	case InputScroll:
		if math.Abs(float64(ny)) >= 1 {
			sendMouse(mouseWheel, 0, 0, uint32(int32(ny*4)))
		}
		if math.Abs(float64(nx)) >= 1 {
			sendMouse(mouseHWheel, 0, 0, uint32(int32(-nx*4)))
		}
	case InputKeyChar:
		if keyData > 0 && keyData <= 0xFFFF {
			var k1, k2 keyInputUnion
			k1.Type = inputKeyboard
			k1.Ki = keybdInput{WScan: uint16(keyData), DwFlags: keyEventUni}
			k2.Type = inputKeyboard
			k2.Ki = keybdInput{WScan: uint16(keyData), DwFlags: keyEventUni | keyEventKeyUp}
			procSendInput.Call(1, uintptr(unsafe.Pointer(&k1)), unsafe.Sizeof(k1))
			procSendInput.Call(1, uintptr(unsafe.Pointer(&k2)), unsafe.Sizeof(k2))
		}
	case InputKeySpecial:
		var vk uint16
		switch keyData {
		case 1:
			vk = 0x0D // VK_RETURN
		case 2:
			vk = 0x08 // VK_BACK
		case 3:
			vk = 0x09 // VK_TAB
		case 4:
			vk = 0x1B // VK_ESCAPE
		case 5:
			vk = 0x25 // VK_LEFT
		case 6:
			vk = 0x27 // VK_RIGHT
		case 7:
			vk = 0x26 // VK_UP
		case 8:
			vk = 0x28 // VK_DOWN
		}
		if vk != 0 {
			var k1, k2 keyInputUnion
			k1.Type = inputKeyboard
			k1.Ki = keybdInput{WVk: vk}
			k2.Type = inputKeyboard
			k2.Ki = keybdInput{WVk: vk, DwFlags: keyEventKeyUp}
			procSendInput.Call(1, uintptr(unsafe.Pointer(&k1)), unsafe.Sizeof(k1))
			procSendInput.Call(1, uintptr(unsafe.Pointer(&k2)), unsafe.Sizeof(k2))
		}
	}
}
