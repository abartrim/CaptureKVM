package input

import "testing"

func TestParseKeyboardPayload(t *testing.T) {
	payload := []byte{0x02, 0x00, 0x04, 0, 0, 0, 0, 0}
	report, err := ParseKeyboardPayload(payload)
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	if report[2] != 0x04 {
		t.Fatalf("expected usage 0x04, got 0x%02x", report[2])
	}
}

func TestClampMouseDelta(t *testing.T) {
	if ClampMouseDelta(500) != 127 {
		t.Fatal("expected positive clamp")
	}
	if ClampMouseDelta(-500) != -127 {
		t.Fatal("expected negative clamp")
	}
}
