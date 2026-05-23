package udp

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	ProtocolVersion = 1
	HeaderSize      = 30
	TagSize         = 16
)

var Magic = [4]byte{'C', 'K', 'V', 'M'}

type PacketKind uint8

const (
	PacketKindInputKeyboard PacketKind = 0x01
	PacketKindInputMouse    PacketKind = 0x02
	PacketKindInputPing     PacketKind = 0x03
	PacketKindVideoConfig   PacketKind = 0x10
	PacketKindVideoFrame    PacketKind = 0x11
	PacketKindVideoPing     PacketKind = 0x12
	PacketKindTelemetry     PacketKind = 0x20
)

type Header struct {
	Version     uint8
	PacketKind  PacketKind
	Flags       uint16
	SessionID   uint64
	Sequence    uint32
	TimestampUS uint64
	PayloadLen  uint16
}

func (h Header) MarshalBinary() []byte {
	buf := make([]byte, HeaderSize)
	copy(buf[:4], Magic[:])
	buf[4] = h.Version
	buf[5] = byte(h.PacketKind)
	binary.BigEndian.PutUint16(buf[6:8], h.Flags)
	binary.BigEndian.PutUint64(buf[8:16], h.SessionID)
	binary.BigEndian.PutUint32(buf[16:20], h.Sequence)
	binary.BigEndian.PutUint64(buf[20:28], h.TimestampUS)
	binary.BigEndian.PutUint16(buf[28:30], h.PayloadLen)
	return buf
}

func ParseHeader(datagram []byte) (Header, error) {
	if len(datagram) < HeaderSize {
		return Header{}, errors.New("packet too short")
	}
	if string(datagram[:4]) != string(Magic[:]) {
		return Header{}, errors.New("invalid magic")
	}
	h := Header{
		Version:     datagram[4],
		PacketKind:  PacketKind(datagram[5]),
		Flags:       binary.BigEndian.Uint16(datagram[6:8]),
		SessionID:   binary.BigEndian.Uint64(datagram[8:16]),
		Sequence:    binary.BigEndian.Uint32(datagram[16:20]),
		TimestampUS: binary.BigEndian.Uint64(datagram[20:28]),
		PayloadLen:  binary.BigEndian.Uint16(datagram[28:30]),
	}
	if h.Version != ProtocolVersion {
		return Header{}, fmt.Errorf("unsupported protocol version %d", h.Version)
	}
	return h, nil
}
