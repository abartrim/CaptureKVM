package udp

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
	"github.com/abartrim/CaptureKVM/agent/internal/control"
	"github.com/abartrim/CaptureKVM/agent/internal/hid"
)

func TestAESGCMRoundTripAndTamperDetection(t *testing.T) {
	key := make([]byte, 32)
	for i := range key {
		key[i] = byte(i)
	}
	sessionID := uint64(0x1122334455667788)
	crypto, err := NewCryptoSession(sessionID, key)
	if err != nil {
		t.Fatal(err)
	}

	header := Header{
		Version:     ProtocolVersion,
		PacketKind:  PacketKindInputKeyboard,
		SessionID:   sessionID,
		Sequence:    7,
		TimestampUS: 1234,
	}
	packet, err := crypto.Seal(header, []byte{1, 0, 4, 0, 0, 0, 0, 0}, DirectionClientToServer)
	if err != nil {
		t.Fatal(err)
	}
	gotHeader, payload, err := crypto.Open(packet, DirectionClientToServer)
	if err != nil {
		t.Fatal(err)
	}
	if gotHeader.Sequence != 7 || len(payload) != 8 {
		t.Fatalf("unexpected round-trip result: header=%+v payload=%v", gotHeader, payload)
	}

	packet[10] ^= 0xFF
	if _, _, err := crypto.Open(packet, DirectionClientToServer); err == nil {
		t.Fatal("expected modified header to fail authentication")
	}
}

func TestNonceUniqueness(t *testing.T) {
	a := string(Nonce(1, DirectionClientToServer, 1))
	b := string(Nonce(1, DirectionClientToServer, 2))
	c := string(Nonce(1, DirectionServerToClient, 1))
	if a == b || a == c || b == c {
		t.Fatal("expected unique nonces across direction and sequence")
	}
}

func TestInputReceiverRejectsReplayAndAcceptsInput(t *testing.T) {
	cfg := config.Default(true)
	backend := hid.NewMock(nil)
	if err := backend.Open(context.Background()); err != nil {
		t.Fatal(err)
	}
	sessions := control.NewManager(time.Minute)
	session, err := sessions.Create()
	if err != nil {
		t.Fatal(err)
	}
	receiver, err := NewInputReceiver(cfg.UDP, sessions, backend, nil)
	if err != nil {
		t.Fatal(err)
	}
	crypto, err := NewCryptoSession(session.ID, session.Key[:])
	if err != nil {
		t.Fatal(err)
	}

	header := Header{
		Version:     ProtocolVersion,
		PacketKind:  PacketKindInputKeyboard,
		SessionID:   session.ID,
		Sequence:    1,
		TimestampUS: 100,
	}
	packet, err := crypto.Seal(header, []byte{0, 0, 4, 0, 0, 0, 0, 0}, DirectionClientToServer)
	if err != nil {
		t.Fatal(err)
	}
	if err := receiver.HandleDatagram(context.Background(), packet, &net.UDPAddr{}); err != nil {
		t.Fatalf("expected packet acceptance: %v", err)
	}
	if err := receiver.HandleDatagram(context.Background(), packet, &net.UDPAddr{}); err == nil {
		t.Fatal("expected replay rejection")
	}
}

func TestInputReceiverRejectsWrongVersion(t *testing.T) {
	header := Header{
		Version:     9,
		PacketKind:  PacketKindInputPing,
		SessionID:   1,
		Sequence:    1,
		TimestampUS: 1,
	}
	packet := header.MarshalBinary()
	if _, err := ParseHeader(packet); err == nil {
		t.Fatal("expected version rejection")
	}
}
