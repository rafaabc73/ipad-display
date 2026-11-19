package main

import (
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"io"
	"math"
	"net"
)

const (
	TCPPort  = 23456
	HTTPPort = 8080

	MsgHello       = 0x01
	MsgDisplayInfo = 0x02
	MsgTileBatch   = 0x05
	MsgCursor      = 0x06
	MsgInput       = 0x07
	MsgControl     = 0x08
	MsgPing        = 0x09
	MsgPong        = 0x0A
	MsgFrameAck    = 0x0B

	ModeIdle   = 0
	ModeSecond = 1
	ModeMirror = 2

	PresetRetina    = 0
	PresetWorkspace = 1
	PresetSmooth    = 2

	TransportUSB  = 1
	TransportWiFi = 2

	OSWindows = 2

	TileFlagFullSync = 1 << 0
	TileFlagHalfRes  = 1 << 1

	EncLZ4BGRA   = 1
	EncRawBGRA   = 3
	EncLZ4RGB565 = 4
	EncRawRGB565 = 5

	InputMove        = 1
	InputLeftDown    = 2
	InputLeftUp      = 3
	InputRightDown   = 4
	InputRightUp     = 5
	InputScroll      = 6
	InputKeyChar     = 7
	InputDoubleClick = 8
	InputLeftDrag    = 9
	InputKeySpecial  = 10

	CtrlSetMode     = 1
	CtrlSetPreset   = 2
	CtrlSetPosition = 3
	CtrlRequestSync = 4
)

type IPD2Header struct {
	Type       uint8
	Flags      uint8
	Extra      uint16
	Seq        uint32
	PayloadLen uint32
}

func encodeHeader(h IPD2Header) [16]byte {
	var b [16]byte
	b[0], b[1], b[2], b[3] = 'I', 'P', 'D', '2'
	b[4] = h.Type
	b[5] = h.Flags
	binary.LittleEndian.PutUint16(b[6:8], h.Extra)
	binary.LittleEndian.PutUint32(b[8:12], h.Seq)
	binary.LittleEndian.PutUint32(b[12:16], h.PayloadLen)
	return b
}

func decodeHeader(b []byte) (IPD2Header, bool) {
	var h IPD2Header
	if len(b) < 16 || b[0] != 'I' || b[1] != 'P' || b[2] != 'D' || b[3] != '2' {
		return h, false
	}
	h.Type = b[4]
	h.Flags = b[5]
	h.Extra = binary.LittleEndian.Uint16(b[6:8])
	h.Seq = binary.LittleEndian.Uint32(b[8:12])
	h.PayloadLen = binary.LittleEndian.Uint32(b[12:16])
	return h, true
}

func encodeDisplayInfo(mode, preset, transport uint8, fbW, fbH, logW, logH, fps, rttTenth uint16, hasVD uint8, hostName string) []byte {
	buf := make([]byte, 64)
	buf[0] = mode
	buf[1] = preset
	buf[2] = transport
	buf[3] = OSWindows
	binary.LittleEndian.PutUint16(buf[4:6], fbW)
	binary.LittleEndian.PutUint16(buf[6:8], fbH)
	binary.LittleEndian.PutUint16(buf[8:10], logW)
	binary.LittleEndian.PutUint16(buf[10:12], logH)
	binary.LittleEndian.PutUint16(buf[12:14], 0)
	binary.LittleEndian.PutUint16(buf[14:16], 0)
	binary.LittleEndian.PutUint16(buf[16:18], fps)
	binary.LittleEndian.PutUint16(buf[18:20], rttTenth)
	buf[20] = 0
	buf[21] = hasVD
	copy(buf[22:63], []byte(hostName))
	return buf
}

func encodeCursor(nx, ny float32, visible uint8) []byte {
	buf := make([]byte, 16)
	binary.LittleEndian.PutUint32(buf[0:4], math.Float32bits(nx))
	binary.LittleEndian.PutUint32(buf[4:8], math.Float32bits(ny))
	buf[8] = visible
	return buf
}

func wsAcceptKey(clientKey string) string {
	h := sha1.New()
	h.Write([]byte(clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

func writeWSBinaryFrame(conn net.Conn, hdr [16]byte, payload []byte) error {
	total := len(hdr) + len(payload)
	var wsHdr [10]byte
	wsHdr[0] = 0x82
	nHdr := 0
	if total < 126 {
		wsHdr[1] = byte(total)
		nHdr = 2
	} else if total <= 65535 {
		wsHdr[1] = 126
		binary.BigEndian.PutUint16(wsHdr[2:4], uint16(total))
		nHdr = 4
	} else {
		wsHdr[1] = 127
		binary.BigEndian.PutUint64(wsHdr[2:10], uint64(total))
		nHdr = 10
	}
	if err := writeAll(conn, wsHdr[:nHdr]); err != nil {
		return err
	}
	if err := writeAll(conn, hdr[:]); err != nil {
		return err
	}
	if len(payload) > 0 {
		return writeAll(conn, payload)
	}
	return nil
}

func readWSFrame(r io.Reader) (opcode byte, data []byte, err error) {
	var b [2]byte
	if _, err = io.ReadFull(r, b[:]); err != nil {
		return 0, nil, err
	}
	opcode = b[0] & 0x0F
	masked := (b[1] & 0x80) != 0
	plen := uint64(b[1] & 0x7F)
	if plen == 126 {
		var ext [2]byte
		if _, err = io.ReadFull(r, ext[:]); err != nil {
			return 0, nil, err
		}
		plen = uint64(binary.BigEndian.Uint16(ext[:]))
	} else if plen == 127 {
		var ext [8]byte
		if _, err = io.ReadFull(r, ext[:]); err != nil {
			return 0, nil, err
		}
		plen = binary.BigEndian.Uint64(ext[:])
	}
	if plen > 2*1024*1024 {
		return 0, nil, io.ErrShortBuffer
	}
	var mask [4]byte
	if masked {
		if _, err = io.ReadFull(r, mask[:]); err != nil {
			return 0, nil, err
		}
	}
	data = make([]byte, plen)
	if plen > 0 {
		if _, err = io.ReadFull(r, data); err != nil {
			return 0, nil, err
		}
		if masked {
			for i := range data {
				data[i] ^= mask[i&3]
			}
		}
	}
	return opcode, data, nil
}

func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		b = b[n:]
	}
	return nil
}

// Fast pure-Go LZ4 block compressor (100% standard LZ4 block format, zero external deps!)
func lz4CompressBlock(src, dst []byte) int {
	n := len(src)
	if n == 0 {
		return 0
	}
	if n < 13 {
		return lz4EmitLastLiterals(src, dst, 0)
	}

	const hashLog = 14
	const hashSize = 1 << hashLog
	var table [hashSize]int32

	s := 0
	anchor := 0
	d := 0
	mflimit := n - 12
	limit := n - 5

	for s < mflimit {
		v := binary.LittleEndian.Uint32(src[s : s+4])
		h := (v * 2654435761) >> (32 - hashLog)
		ref := int(table[h])
		table[h] = int32(s)

		offset := s - ref
		if offset <= 0 || offset > 65535 || binary.LittleEndian.Uint32(src[ref:ref+4]) != v {
			s += 1 + ((s - anchor) >> 6)
			continue
		}

		// Match found!
		litLen := s - anchor
		if d+litLen+litLen/255+8 >= len(dst) {
			return 0
		}

		tokenPos := d
		d++
		var token byte
		if litLen >= 15 {
			token = 0xF0
			rem := litLen - 15
			for rem >= 255 {
				dst[d] = 255
				d++
				rem -= 255
			}
			dst[d] = byte(rem)
			d++
		} else {
			token = byte(litLen << 4)
		}

		copy(dst[d:], src[anchor:s])
		d += litLen

		// Offset (little-endian uint16)
		dst[d] = byte(offset)
		dst[d+1] = byte(offset >> 8)
		d += 2

		// Extend match length
		s += 4
		ref += 4
		matchStart := s
		for s < limit && src[s] == src[ref] {
			s++
			ref++
		}
		matchLen := s - matchStart
		if matchLen >= 15 {
			token |= 0x0F
			rem := matchLen - 15
			for rem >= 255 {
				if d >= len(dst) {
					return 0
				}
				dst[d] = 255
				d++
				rem -= 255
			}
			if d >= len(dst) {
				return 0
			}
			dst[d] = byte(rem)
			d++
		} else {
			token |= byte(matchLen)
		}
		dst[tokenPos] = token
		anchor = s
	}

	return lz4EmitLastLiterals(src[anchor:], dst, d)
}

func lz4EmitLastLiterals(lit, dst []byte, d int) int {
	litLen := len(lit)
	if d+1+litLen/255+1+litLen > len(dst) {
		return 0
	}
	if litLen >= 15 {
		dst[d] = 0xF0
		d++
		rem := litLen - 15
		for rem >= 255 {
			dst[d] = 255
			d++
			rem -= 255
		}
		dst[d] = byte(rem)
		d++
	} else {
		dst[d] = byte(litLen << 4)
		d++
	}
	copy(dst[d:], lit)
	return d + litLen
}
