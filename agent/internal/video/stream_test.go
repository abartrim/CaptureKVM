package video

import (
	"context"
	"testing"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
)

func TestStreamStatusReflectsConfig(t *testing.T) {
	stream := NewStream(config.VideoConfig{
		Source: "/dev/video0",
		Codec:  "h264",
	}, nil)
	status := stream.Status()
	if status.Healthy {
		t.Fatal("expected stream to stay unhealthy before start")
	}
}

func TestAnnexBParserSplitsOnAUD(t *testing.T) {
	var units []AccessUnit
	parser := NewAnnexBParser(func(unit AccessUnit) error {
		units = append(units, unit)
		return nil
	})
	stream := []byte{
		0x00, 0x00, 0x00, 0x01, 0x09, 0x10,
		0x00, 0x00, 0x00, 0x01, 0x67, 0x64,
		0x00, 0x00, 0x00, 0x01, 0x65, 0x88,
		0x00, 0x00, 0x00, 0x01, 0x09, 0x10,
		0x00, 0x00, 0x00, 0x01, 0x41, 0x9A,
	}
	if err := parser.Feed(stream[:11]); err != nil {
		t.Fatal(err)
	}
	if err := parser.Feed(stream[11:]); err != nil {
		t.Fatal(err)
	}
	if err := parser.Flush(); err != nil {
		t.Fatal(err)
	}
	if len(units) != 2 {
		t.Fatalf("expected 2 access units, got %d", len(units))
	}
	if !units[0].Keyframe {
		t.Fatal("expected first access unit to be keyframe")
	}
	if units[1].Keyframe {
		t.Fatal("expected second access unit to be non-keyframe")
	}
}

func TestStreamPublishesNewestFrame(t *testing.T) {
	stream := NewStream(config.VideoConfig{Source: "/dev/video0", Codec: "h264"}, nil)
	ch, cancel := stream.Subscribe()
	defer cancel()

	stream.Publish(AccessUnit{Data: []byte{0x00, 0x00, 0x01, 0x09}, Keyframe: false})

	select {
	case frame := <-ch:
		if len(frame.Data) == 0 {
			t.Fatal("expected frame data")
		}
	case <-context.Background().Done():
	}
}
