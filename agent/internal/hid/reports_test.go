package hid

import (
	"bytes"
	"testing"
)

func TestFrameProducesTerminatedCOBSPacket(t *testing.T) {
	frame := Frame(0x01, []byte{0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00})
	if frame[len(frame)-1] != 0x00 {
		t.Fatal("expected trailing delimiter")
	}
	if bytes.Contains(frame[:len(frame)-1], []byte{0x00}) {
		t.Fatal("expected zero-free encoded body")
	}
}

func TestCRC8MatchesKnownValue(t *testing.T) {
	got := CRC8([]byte{0x80})
	if got != 0x89 {
		t.Fatalf("unexpected crc: 0x%02x", got)
	}
}
