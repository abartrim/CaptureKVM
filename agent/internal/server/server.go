package server

import (
	"context"
	"log"
	"net/http"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
	"github.com/abartrim/CaptureKVM/agent/internal/control"
	"github.com/abartrim/CaptureKVM/agent/internal/hid"
	"github.com/abartrim/CaptureKVM/agent/internal/udp"
	"github.com/abartrim/CaptureKVM/agent/internal/video"
)

type Server struct {
	cfg           config.Config
	version       string
	backend       hid.Backend
	sessions      *control.Manager
	inputReceiver *udp.InputReceiver
	videoStream   *video.Stream
	logger        *log.Logger
	httpServer    *http.Server
}

func New(cfg config.Config, version string, backend hid.Backend, sessions *control.Manager, inputReceiver *udp.InputReceiver, videoStream *video.Stream, logger *log.Logger) *Server {
	s := &Server{
		cfg:           cfg,
		version:       version,
		backend:       backend,
		sessions:      sessions,
		inputReceiver: inputReceiver,
		videoStream:   videoStream,
		logger:        logger,
	}
	s.httpServer = &http.Server{
		Addr:    cfg.Server.Bind,
		Handler: s.routes(),
	}
	return s
}

func (s *Server) Run() error {
	return s.httpServer.ListenAndServe()
}

func (s *Server) Shutdown(ctx context.Context) error {
	return s.httpServer.Shutdown(ctx)
}

func (s *Server) Handler() http.Handler {
	return s.httpServer.Handler
}
