package video

import "github.com/abartrim/CaptureKVM/agent/internal/config"

type Encoder struct {
	Config config.VideoConfig
}

func NewEncoder(cfg config.VideoConfig) *Encoder {
	return &Encoder{Config: cfg}
}
