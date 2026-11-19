package main

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func decompressRef(src []byte, maxOut int) ([]byte, bool) {
	ip := 0
	dst := make([]byte, 0, maxOut)
	for ip < len(src) {
		token := src[ip]
		ip++
		litLen := int(token >> 4)
		if litLen == 15 {
			for {
				if ip >= len(src) {
					return nil, false
				}
				s := src[ip]
				ip++
				litLen += int(s)
				if s != 255 {
					break
				}
			}
		}
		if ip+litLen > len(src) {
			return nil, false
		}
		dst = append(dst, src[ip:ip+litLen]...)
		ip += litLen
		if ip >= len(src) {
			break
		}
		if ip+2 > len(src) {
			return nil, false
		}
		offset := int(binary.LittleEndian.Uint16(src[ip : ip+2]))
		ip += 2
		if offset == 0 || offset > len(dst) {
			return nil, false
		}
		matchLen := int(token&15) + 4
		if (token & 15) == 15 {
			for {
				if ip >= len(src) {
					return nil, false
				}
				m := src[ip]
				ip++
				matchLen += int(m)
				if m != 255 {
					break
				}
			}
		}
		ref := len(dst) - offset
		for i := 0; i < matchLen; i++ {
			dst = append(dst, dst[ref])
			ref++
		}
	}
	return dst, true
}

func TestLZ4RoundTrip(t *testing.T) {
	raw := make([]byte, 128*128*4)
	for i := 0; i < len(raw); i += 4 {
		if i < 20000 {
			raw[i], raw[i+1], raw[i+2], raw[i+3] = 240, 242, 245, 255
		} else if i < 45000 {
			raw[i], raw[i+1], raw[i+2], raw[i+3] = byte(i>>2), byte((i>>4)*7), 90, 255
		} else {
			raw[i], raw[i+1], raw[i+2], raw[i+3] = byte(i*31), byte(i*17), byte(i*13), 255
		}
	}
	dst := make([]byte, len(raw)+8192)
	n := lz4CompressBlock(raw, dst)
	if n <= 0 || n >= len(raw) {
		t.Fatalf("unexpected compressed length %d (raw %d)", n, len(raw))
	}
	dec, ok := decompressRef(dst[:n], len(raw))
	if !ok || !bytes.Equal(dec, raw) {
		t.Fatalf("LZ4 round-trip mismatch! ok=%v decLen=%d", ok, len(dec))
	}
	t.Logf("Go LZ4 compressed %d -> %d bytes (%.1fx), bit-exact verified!", len(raw), n, float64(len(raw))/float64(n))
}
