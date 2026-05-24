package video

import (
	"context"
	"errors"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
)

type Status struct {
	Healthy     bool   `json:"healthy"`
	Detail      string `json:"detail"`
	Frames      uint64 `json:"frames"`
	Subscribers int    `json:"subscribers"`
}

type Frame struct {
	ID          uint32
	Data        []byte
	Keyframe    bool
	TimestampUS uint64
}

type Stream struct {
	cfg    config.VideoConfig
	logger *log.Logger

	encoder *Encoder

	mu         sync.Mutex
	healthy    bool
	detail     string
	nextFrame  uint32
	nextSubID  int
	subs       map[int]chan Frame
	framesSent atomic.Uint64
}

func NewStream(cfg config.VideoConfig, logger *log.Logger) *Stream {
	return &Stream{
		cfg:     cfg,
		logger:  logger,
		encoder: NewEncoder(cfg, logger),
		healthy: false,
		detail:  "encoder not started",
		subs:    make(map[int]chan Frame),
	}
}

func (s *Stream) Start(ctx context.Context) error {
	s.setStatus(true, "starting encoder")
	go s.run(ctx)
	return nil
}

func (s *Stream) Subscribe() (<-chan Frame, func()) {
	s.mu.Lock()
	defer s.mu.Unlock()

	id := s.nextSubID
	s.nextSubID++
	ch := make(chan Frame, 1)
	s.subs[id] = ch
	return ch, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if sub, ok := s.subs[id]; ok {
			delete(s.subs, id)
			close(sub)
		}
	}
}

func (s *Stream) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return Status{
		Healthy:     s.healthy,
		Detail:      s.detail,
		Frames:      s.framesSent.Load(),
		Subscribers: len(s.subs),
	}
}

func (s *Stream) Publish(unit AccessUnit) {
	if len(unit.Data) == 0 {
		return
	}

	s.mu.Lock()
	frame := Frame{
		ID:          s.nextFrame,
		Data:        append([]byte(nil), unit.Data...),
		Keyframe:    unit.Keyframe,
		TimestampUS: uint64(time.Now().UnixMicro()),
	}
	s.nextFrame++
	subs := make([]chan Frame, 0, len(s.subs))
	for _, ch := range s.subs {
		subs = append(subs, ch)
	}
	s.mu.Unlock()

	for _, ch := range subs {
		select {
		case ch <- frame:
		default:
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- frame:
			default:
			}
		}
	}
	s.framesSent.Add(1)
}

func (s *Stream) run(ctx context.Context) {
	err := s.encoder.Run(ctx, func(unit AccessUnit) error {
		s.Publish(unit)
		s.setStatus(true, "streaming")
		return nil
	})
	if err != nil && !errors.Is(err, context.Canceled) {
		s.setStatus(false, err.Error())
		return
	}
	s.setStatus(false, "stopped")
}

func (s *Stream) setStatus(healthy bool, detail string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.healthy = healthy
	s.detail = detail
}
