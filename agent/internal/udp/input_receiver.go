package udp

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"sync/atomic"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
	"github.com/abartrim/CaptureKVM/agent/internal/control"
	"github.com/abartrim/CaptureKVM/agent/internal/hid"
	"github.com/abartrim/CaptureKVM/agent/internal/input"
)

type InputStatus struct {
	Counters map[string]uint64 `json:"counters"`
}

type InputReceiver struct {
	cfg      config.UDPConfig
	sessions *control.Manager
	backend  hid.Backend
	logger   *log.Logger

	conn *net.UDPConn

	mu      sync.Mutex
	windows map[uint64]map[PacketKind]*replayWindow

	packetsAccepted atomic.Uint64
	packetsDropped  atomic.Uint64
	packetsLate     atomic.Uint64
	packetsInvalid  atomic.Uint64
	authFailures    atomic.Uint64
}

func NewInputReceiver(cfg config.UDPConfig, sessions *control.Manager, backend hid.Backend, logger *log.Logger) (*InputReceiver, error) {
	if cfg.MTU <= HeaderSize+TagSize {
		return nil, fmt.Errorf("udp mtu %d is too small", cfg.MTU)
	}
	return &InputReceiver{
		cfg:      cfg,
		sessions: sessions,
		backend:  backend,
		logger:   logger,
		windows:  make(map[uint64]map[PacketKind]*replayWindow),
	}, nil
}

func (r *InputReceiver) Start(ctx context.Context) error {
	addr, err := net.ResolveUDPAddr("udp", r.cfg.InputListenAddr())
	if err != nil {
		return err
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return err
	}
	r.conn = conn

	go func() {
		<-ctx.Done()
		_ = r.Close()
	}()

	go r.readLoop()
	return nil
}

func (r *InputReceiver) Close() error {
	if r.conn == nil {
		return nil
	}
	return r.conn.Close()
}

func (r *InputReceiver) Status() InputStatus {
	return InputStatus{
		Counters: map[string]uint64{
			"accepted":     r.packetsAccepted.Load(),
			"dropped":      r.packetsDropped.Load(),
			"late":         r.packetsLate.Load(),
			"invalid":      r.packetsInvalid.Load(),
			"auth_failure": r.authFailures.Load(),
		},
	}
}

func (r *InputReceiver) readLoop() {
	buf := make([]byte, r.cfg.MTU+HeaderSize+TagSize)
	for {
		n, addr, err := r.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		if err := r.HandleDatagram(context.Background(), buf[:n], addr); err != nil && r.logger != nil {
			r.logger.Printf("drop input packet from %s: %v", addr, err)
		}
	}
}

func (r *InputReceiver) HandleDatagram(ctx context.Context, datagram []byte, _ net.Addr) error {
	header, err := ParseHeader(datagram)
	if err != nil {
		r.packetsInvalid.Add(1)
		return err
	}
	session, ok := r.sessions.Get(header.SessionID)
	if !ok {
		r.packetsDropped.Add(1)
		return errors.New("unknown or expired session")
	}
	crypto, err := NewCryptoSession(session.ID, session.Key[:])
	if err != nil {
		r.packetsInvalid.Add(1)
		return err
	}
	header, payload, err := crypto.Open(datagram, DirectionClientToServer)
	if err != nil {
		r.authFailures.Add(1)
		return err
	}
	if !r.acceptSequence(header.SessionID, header.PacketKind, header.Sequence) {
		r.packetsLate.Add(1)
		return errors.New("stale or replayed packet")
	}

	switch header.PacketKind {
	case PacketKindInputKeyboard:
		report, err := input.ParseKeyboardPayload(payload)
		if err != nil {
			r.packetsInvalid.Add(1)
			return err
		}
		if err := r.backend.SendKeyboardReport(ctx, report); err != nil {
			return err
		}
	case PacketKindInputMouse:
		report, err := input.ParseMousePayload(payload)
		if err != nil {
			r.packetsInvalid.Add(1)
			return err
		}
		if err := r.backend.SendMouseReport(ctx, report); err != nil {
			return err
		}
	case PacketKindInputPing:
		if err := r.backend.Ping(ctx); err != nil {
			return err
		}
	default:
		r.packetsDropped.Add(1)
		return fmt.Errorf("unsupported input packet kind %d", header.PacketKind)
	}

	r.packetsAccepted.Add(1)
	return nil
}

func (r *InputReceiver) acceptSequence(sessionID uint64, kind PacketKind, seq uint32) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	sessionWindows := r.windows[sessionID]
	if sessionWindows == nil {
		sessionWindows = make(map[PacketKind]*replayWindow)
		r.windows[sessionID] = sessionWindows
	}
	window := sessionWindows[kind]
	if window == nil {
		window = &replayWindow{}
		sessionWindows[kind] = window
	}
	return window.Accept(seq)
}
