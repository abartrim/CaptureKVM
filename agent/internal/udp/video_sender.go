package udp

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"sync/atomic"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
	"github.com/abartrim/CaptureKVM/agent/internal/control"
	"github.com/abartrim/CaptureKVM/agent/internal/video"
)

const (
	videoFlagKeyframe       uint16 = 1 << 0
	videoConfigPayloadSize         = 20
	videoFragmentHeaderSize        = 12
)

type VideoSenderStatus struct {
	Counters map[string]uint64 `json:"counters"`
	Peers    int               `json:"peers"`
}

type videoPeer struct {
	addr       *net.UDPAddr
	configSent bool
	nextSeq    uint32
}

type VideoSender struct {
	udpCfg   config.UDPConfig
	videoCfg config.VideoConfig
	sessions *control.Manager
	stream   *video.Stream
	logger   *log.Logger

	conn *net.UDPConn

	mu    sync.Mutex
	peers map[uint64]*videoPeer

	pingsAccepted atomic.Uint64
	pingsRejected atomic.Uint64
	framesSent    atomic.Uint64
	packetsSent   atomic.Uint64
	sendErrors    atomic.Uint64
}

func NewVideoSender(udpCfg config.UDPConfig, videoCfg config.VideoConfig, sessions *control.Manager, stream *video.Stream, logger *log.Logger) (*VideoSender, error) {
	if udpCfg.MTU <= HeaderSize+TagSize+videoFragmentHeaderSize {
		return nil, fmt.Errorf("udp mtu %d is too small for video payloads", udpCfg.MTU)
	}
	return &VideoSender{
		udpCfg:   udpCfg,
		videoCfg: videoCfg,
		sessions: sessions,
		stream:   stream,
		logger:   logger,
		peers:    make(map[uint64]*videoPeer),
	}, nil
}

func (s *VideoSender) Start(ctx context.Context) error {
	addr, err := net.ResolveUDPAddr("udp", s.udpCfg.VideoListenAddr())
	if err != nil {
		return err
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return err
	}
	s.conn = conn

	frames, unsubscribe := s.stream.Subscribe()
	go func() {
		<-ctx.Done()
		unsubscribe()
		_ = s.Close()
	}()
	go s.readLoop()
	go s.sendLoop(frames)
	return nil
}

func (s *VideoSender) Close() error {
	if s.conn == nil {
		return nil
	}
	return s.conn.Close()
}

func (s *VideoSender) Status() VideoSenderStatus {
	s.mu.Lock()
	peerCount := len(s.peers)
	s.mu.Unlock()
	return VideoSenderStatus{
		Counters: map[string]uint64{
			"video_pings":    s.pingsAccepted.Load(),
			"video_rejected": s.pingsRejected.Load(),
			"frames_sent":    s.framesSent.Load(),
			"packets_sent":   s.packetsSent.Load(),
			"send_errors":    s.sendErrors.Load(),
		},
		Peers: peerCount,
	}
}

func (s *VideoSender) readLoop() {
	buf := make([]byte, s.udpCfg.MTU+HeaderSize+TagSize)
	for {
		n, addr, err := s.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		if err := s.handleControlDatagram(buf[:n], addr); err != nil && s.logger != nil {
			s.logger.Printf("drop video control packet from %s: %v", addr, err)
		}
	}
}

func (s *VideoSender) handleControlDatagram(datagram []byte, addr *net.UDPAddr) error {
	header, err := ParseHeader(datagram)
	if err != nil {
		s.pingsRejected.Add(1)
		return err
	}
	session, ok := s.sessions.Get(header.SessionID)
	if !ok {
		s.pingsRejected.Add(1)
		return errors.New("unknown or expired session")
	}
	crypto, err := NewCryptoSession(session.ID, session.Key[:])
	if err != nil {
		s.pingsRejected.Add(1)
		return err
	}
	header, payload, err := crypto.Open(datagram, DirectionClientToServer)
	if err != nil {
		s.pingsRejected.Add(1)
		return err
	}
	if header.PacketKind != PacketKindVideoPing {
		s.pingsRejected.Add(1)
		return fmt.Errorf("unsupported video control packet kind %d", header.PacketKind)
	}
	if len(payload) != 0 {
		s.pingsRejected.Add(1)
		return errors.New("video ping payload must be empty")
	}

	s.registerPeer(session.ID, addr)
	s.pingsAccepted.Add(1)
	if s.conn != nil {
		return s.sendConfig(session, addr)
	}
	return nil
}

func (s *VideoSender) sendLoop(frames <-chan video.Frame) {
	for frame := range frames {
		s.broadcastFrame(frame)
	}
}

func (s *VideoSender) broadcastFrame(frame video.Frame) {
	if len(frame.Data) == 0 {
		return
	}
	peers := s.snapshotPeers()
	if len(peers) == 0 {
		return
	}
	for sessionID, peer := range peers {
		session, ok := s.sessions.Get(sessionID)
		if !ok {
			s.removePeer(sessionID)
			continue
		}
		if !peer.configSent {
			if err := s.sendConfig(session, peer.addr); err != nil {
				s.sendErrors.Add(1)
				continue
			}
		}
		if err := s.sendFrame(session, peer.addr, frame); err != nil {
			s.sendErrors.Add(1)
			if s.logger != nil {
				s.logger.Printf("send video frame: %v", err)
			}
		}
	}
}

func (s *VideoSender) sendConfig(session *control.Session, addr *net.UDPAddr) error {
	payload := encodeVideoConfigPayload(s.videoCfg)
	if err := s.sendPacket(session, addr, PacketKindVideoConfig, 0, uint64(session.CreatedAt.UnixMicro()), payload); err != nil {
		return err
	}
	s.mu.Lock()
	if peer, ok := s.peers[session.ID]; ok {
		peer.configSent = true
	}
	s.mu.Unlock()
	return nil
}

func (s *VideoSender) sendFrame(session *control.Session, addr *net.UDPAddr, frame video.Frame) error {
	chunks := fragmentVideoFrame(frame, s.udpCfg.MTU)
	flags := uint16(0)
	if frame.Keyframe {
		flags |= videoFlagKeyframe
	}
	for _, chunk := range chunks {
		if err := s.sendPacket(session, addr, PacketKindVideoFrame, flags, frame.TimestampUS, chunk); err != nil {
			return err
		}
	}
	s.framesSent.Add(1)
	return nil
}

func (s *VideoSender) sendPacket(session *control.Session, addr *net.UDPAddr, kind PacketKind, flags uint16, timestampUS uint64, payload []byte) error {
	if s.conn == nil {
		return errors.New("video socket is not open")
	}
	crypto, err := NewCryptoSession(session.ID, session.Key[:])
	if err != nil {
		return err
	}
	header := Header{
		Version:     ProtocolVersion,
		PacketKind:  kind,
		Flags:       flags,
		SessionID:   session.ID,
		Sequence:    s.nextSequence(session.ID),
		TimestampUS: timestampUS,
	}
	packet, err := crypto.Seal(header, payload, DirectionServerToClient)
	if err != nil {
		return err
	}
	if _, err := s.conn.WriteToUDP(packet, addr); err != nil {
		return err
	}
	s.packetsSent.Add(1)
	return nil
}

func (s *VideoSender) registerPeer(sessionID uint64, addr *net.UDPAddr) {
	s.mu.Lock()
	defer s.mu.Unlock()
	peer := s.peers[sessionID]
	if peer == nil {
		peer = &videoPeer{}
		s.peers[sessionID] = peer
	}
	peer.addr = &net.UDPAddr{IP: append([]byte(nil), addr.IP...), Port: addr.Port, Zone: addr.Zone}
}

func (s *VideoSender) removePeer(sessionID uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.peers, sessionID)
}

func (s *VideoSender) snapshotPeers() map[uint64]videoPeer {
	s.mu.Lock()
	defer s.mu.Unlock()
	peers := make(map[uint64]videoPeer, len(s.peers))
	for id, peer := range s.peers {
		if peer == nil || peer.addr == nil {
			continue
		}
		peers[id] = videoPeer{
			addr:       &net.UDPAddr{IP: append([]byte(nil), peer.addr.IP...), Port: peer.addr.Port, Zone: peer.addr.Zone},
			configSent: peer.configSent,
			nextSeq:    peer.nextSeq,
		}
	}
	return peers
}

func (s *VideoSender) nextSequence(sessionID uint64) uint32 {
	s.mu.Lock()
	defer s.mu.Unlock()
	peer := s.peers[sessionID]
	if peer == nil {
		peer = &videoPeer{}
		s.peers[sessionID] = peer
	}
	peer.nextSeq++
	return peer.nextSeq
}

func encodeVideoConfigPayload(cfg config.VideoConfig) []byte {
	buf := make([]byte, videoConfigPayloadSize)
	buf[0] = 0x01 // h264
	buf[1] = 0x01 // annex-b
	binary.BigEndian.PutUint16(buf[2:4], uint16(cfg.Width))
	binary.BigEndian.PutUint16(buf[4:6], uint16(cfg.Height))
	binary.BigEndian.PutUint16(buf[6:8], uint16(cfg.FPS))
	binary.BigEndian.PutUint32(buf[8:12], uint32(cfg.BitrateKbps))
	binary.BigEndian.PutUint16(buf[12:14], uint16(cfg.KeyframeInterval))
	if cfg.HardwareEncode {
		buf[14] = 1
	}
	if cfg.NoBFrames {
		buf[15] = 1
	}
	return buf
}

func fragmentVideoFrame(frame video.Frame, mtu int) [][]byte {
	maxPayload := mtu - HeaderSize - TagSize - videoFragmentHeaderSize
	if maxPayload <= 0 {
		return nil
	}
	fragmentCount := (len(frame.Data) + maxPayload - 1) / maxPayload
	if fragmentCount == 0 {
		fragmentCount = 1
	}

	fragments := make([][]byte, 0, fragmentCount)
	for i := 0; i < fragmentCount; i++ {
		start := i * maxPayload
		end := start + maxPayload
		if end > len(frame.Data) {
			end = len(frame.Data)
		}
		chunk := make([]byte, videoFragmentHeaderSize+(end-start))
		binary.BigEndian.PutUint32(chunk[0:4], frame.ID)
		binary.BigEndian.PutUint32(chunk[4:8], uint32(len(frame.Data)))
		binary.BigEndian.PutUint16(chunk[8:10], uint16(i))
		binary.BigEndian.PutUint16(chunk[10:12], uint16(fragmentCount))
		copy(chunk[12:], frame.Data[start:end])
		fragments = append(fragments, chunk)
	}
	return fragments
}
