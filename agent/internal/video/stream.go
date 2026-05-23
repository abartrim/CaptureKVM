package video

import "github.com/abartrim/CaptureKVM/agent/internal/config"

type Status struct {
	Healthy bool
	Detail  string
}

type Stream struct {
	cfg config.VideoConfig
}

func NewStream(cfg config.VideoConfig) *Stream {
	return &Stream{cfg: cfg}
}

func (s *Stream) Status() Status {
	healthy := s.cfg.Source != "" && s.cfg.Codec == "h264"
	detail := "configured"
	if !healthy {
		detail = "video source is not fully configured"
	}
	return Status{
		Healthy: healthy,
		Detail:  detail,
	}
}
