package udp

import (
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
	"github.com/abartrim/CaptureKVM/agent/internal/control"
	"github.com/abartrim/CaptureKVM/agent/internal/video"
)

func TestFragmentVideoFrameHonorsMTU(t *testing.T) {
	frame := video.Frame{
		ID:   42,
		Data: make([]byte, 3000),
	}
	fragments := fragmentVideoFrame(frame, 1200)
	if len(fragments) < 2 {
		t.Fatal("expected frame to fragment")
	}
	for _, fragment := range fragments {
		if len(fragment)+HeaderSize+TagSize > 1200 {
			t.Fatalf("fragment exceeds MTU budget: %d", len(fragment)+HeaderSize+TagSize)
		}
	}
	if got := binary.BigEndian.Uint32(fragments[0][0:4]); got != 42 {
		t.Fatalf("unexpected frame ID %d", got)
	}
}

func TestHandleVideoPingRegistersPeer(t *testing.T) {
	cfg := config.Default(true)
	stream := video.NewStream(cfg.Video, nil)
	sessions := control.NewManager(time.Minute)
	session, err := sessions.Create()
	if err != nil {
		t.Fatal(err)
	}
	sender, err := NewVideoSender(cfg.UDP, cfg.Video, sessions, stream, nil)
	if err != nil {
		t.Fatal(err)
	}

	crypto, err := NewCryptoSession(session.ID, session.Key[:])
	if err != nil {
		t.Fatal(err)
	}
	packet, err := crypto.Seal(Header{
		Version:     ProtocolVersion,
		PacketKind:  PacketKindVideoPing,
		SessionID:   session.ID,
		Sequence:    1,
		TimestampUS: 99,
	}, nil, DirectionClientToServer)
	if err != nil {
		t.Fatal(err)
	}

	addr := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 55000}
	if err := sender.handleControlDatagram(packet, addr); err != nil {
		t.Fatalf("handle video ping failed: %v", err)
	}
	peers := sender.snapshotPeers()
	peer, ok := peers[session.ID]
	if !ok {
		t.Fatal("expected peer registration")
	}
	if peer.addr.Port != 55000 {
		t.Fatalf("unexpected peer port %d", peer.addr.Port)
	}
}

func TestEncodeVideoConfigPayload(t *testing.T) {
	payload := encodeVideoConfigPayload(config.VideoConfig{
		Width:            1280,
		Height:           720,
		FPS:              60,
		BitrateKbps:      6000,
		KeyframeInterval: 30,
		HardwareEncode:   true,
		NoBFrames:        true,
	})
	if len(payload) != videoConfigPayloadSize {
		t.Fatalf("unexpected config payload size %d", len(payload))
	}
	if got := binary.BigEndian.Uint16(payload[2:4]); got != 1280 {
		t.Fatalf("unexpected width %d", got)
	}
}

func TestVideoSenderStartAndClose(t *testing.T) {
	cfg := config.Default(true)
	stream := video.NewStream(cfg.Video, nil)
	sessions := control.NewManager(time.Minute)
	sender, err := NewVideoSender(cfg.UDP, cfg.Video, sessions, stream, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := sender.Start(ctx); err != nil {
		t.Fatal(err)
	}
	cancel()
	_ = sender.Close()
}

func TestBroadcastFrameWaitsForKeyframePerPeer(t *testing.T) {
	cfg := config.Default(true)
	stream := video.NewStream(cfg.Video, nil)
	sessions := control.NewManager(time.Minute)
	session, err := sessions.Create()
	if err != nil {
		t.Fatal(err)
	}
	sender, err := NewVideoSender(cfg.UDP, cfg.Video, sessions, stream, nil)
	if err != nil {
		t.Fatal(err)
	}

	senderConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer senderConn.Close()
	sender.conn = senderConn

	peerConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer peerConn.Close()

	sender.registerPeer(session.ID, peerConn.LocalAddr().(*net.UDPAddr))

	sender.broadcastFrame(video.Frame{ID: 1, Data: []byte{0x00, 0x00, 0x00, 0x01, 0x41, 0x9a}, TimestampUS: 1})

	configPacket := readPacketHeader(t, peerConn)
	if configPacket.PacketKind != PacketKindVideoConfig {
		t.Fatalf("expected first packet kind %d, got %d", PacketKindVideoConfig, configPacket.PacketKind)
	}
	assertNoPacketReady(t, peerConn)

	sender.broadcastFrame(video.Frame{ID: 2, Data: []byte{0x00, 0x00, 0x00, 0x01, 0x65, 0x88}, Keyframe: true, TimestampUS: 2})

	framePacket := readPacketHeader(t, peerConn)
	if framePacket.PacketKind != PacketKindVideoFrame {
		t.Fatalf("expected frame packet kind %d, got %d", PacketKindVideoFrame, framePacket.PacketKind)
	}
	assertNoPacketReady(t, peerConn)

	sender.broadcastFrame(video.Frame{ID: 3, Data: []byte{0x00, 0x00, 0x00, 0x01, 0x41, 0x9a}, TimestampUS: 3})

	nextFramePacket := readPacketHeader(t, peerConn)
	if nextFramePacket.PacketKind != PacketKindVideoFrame {
		t.Fatalf("expected subsequent frame packet kind %d, got %d", PacketKindVideoFrame, nextFramePacket.PacketKind)
	}
	assertNoPacketReady(t, peerConn)
}

func readPacketHeader(t *testing.T, conn *net.UDPConn) Header {
	t.Helper()
	buf := make([]byte, 2048)
	if err := conn.SetReadDeadline(time.Now().Add(250 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	n, _, err := conn.ReadFromUDP(buf)
	if err != nil {
		t.Fatal(err)
	}
	header, err := ParseHeader(buf[:n])
	if err != nil {
		t.Fatal(err)
	}
	return header
}

func assertNoPacketReady(t *testing.T, conn *net.UDPConn) {
	t.Helper()
	buf := make([]byte, 256)
	if err := conn.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := conn.ReadFromUDP(buf); err == nil {
		t.Fatal("unexpected extra packet")
	} else if netErr, ok := err.(net.Error); !ok || !netErr.Timeout() {
		t.Fatalf("unexpected read error: %v", err)
	}
}
