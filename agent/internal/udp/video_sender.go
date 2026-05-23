package udp

import "github.com/abartrim/CaptureKVM/agent/internal/config"

type VideoSender struct {
	cfg config.VideoConfig
}

func NewVideoSender(cfg config.VideoConfig) *VideoSender {
	return &VideoSender{cfg: cfg}
}
