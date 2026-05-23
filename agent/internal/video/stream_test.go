package video

import (
	"testing"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
)

func TestStreamStatusReflectsConfig(t *testing.T) {
	stream := NewStream(config.VideoConfig{
		Source: "/dev/video0",
		Codec:  "h264",
	})
	if !stream.Status().Healthy {
		t.Fatal("expected configured stream to be healthy")
	}
}
