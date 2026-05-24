package video

import (
	"testing"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
)

func TestEncoderCommandRepeatsHeadersForFreshClients(t *testing.T) {
	encoder := NewEncoder(config.VideoConfig{
		Source:           "/dev/video0",
		Width:            1280,
		Height:           720,
		FPS:              60,
		BitrateKbps:      6000,
		KeyframeInterval: 30,
		NoBFrames:        true,
	}, nil)

	command, err := encoder.Command()
	if err != nil {
		t.Fatal(err)
	}

	assertCommandContainsPair(t, command, "-x264-params", "repeat-headers=1")
	assertCommandContainsPair(t, command, "-bsf:v", "dump_extra=freq=keyframe,h264_metadata=aud=insert")
	assertCommandContainsPair(t, command, "-fflags", "+genpts+nobuffer")
	assertCommandContainsPair(t, command, "-use_wallclock_as_timestamps", "1")
}

func TestEncoderCommandSkipsX264ParamsForHardwareEncode(t *testing.T) {
	encoder := NewEncoder(config.VideoConfig{
		Source:           "/dev/video0",
		Width:            1280,
		Height:           720,
		FPS:              60,
		BitrateKbps:      6000,
		KeyframeInterval: 30,
		HardwareEncode:   true,
		NoBFrames:        true,
	}, nil)

	command, err := encoder.Command()
	if err != nil {
		t.Fatal(err)
	}

	assertCommandContainsPair(t, command, "-bsf:v", "dump_extra=freq=keyframe,h264_metadata=aud=insert")
	assertCommandOmitsValue(t, command, "-x264-params")
	assertCommandContainsPair(t, command, "-fflags", "+genpts+nobuffer")
	assertCommandContainsPair(t, command, "-use_wallclock_as_timestamps", "1")
}

func assertCommandContainsPair(t *testing.T, command []string, key string, value string) {
	t.Helper()
	for i := 0; i+1 < len(command); i++ {
		if command[i] == key && command[i+1] == value {
			return
		}
	}
	t.Fatalf("expected command to contain %q %q, got %v", key, value, command)
}

func assertCommandOmitsValue(t *testing.T, command []string, key string) {
	t.Helper()
	for _, part := range command {
		if part == key {
			t.Fatalf("expected command to omit %q, got %v", key, command)
		}
	}
}