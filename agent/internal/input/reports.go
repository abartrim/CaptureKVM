package input

import "fmt"

const (
	FrameTypeKeyboardBoot byte = 0x01
	FrameTypeMouseBoot    byte = 0x02
	FrameTypePing         byte = 0x80
)

type KeyboardReport [8]byte
type MouseReport [4]byte

func ParseKeyboardPayload(payload []byte) (KeyboardReport, error) {
	var report KeyboardReport
	if len(payload) != len(report) {
		return report, fmt.Errorf("keyboard report must be %d bytes", len(report))
	}
	copy(report[:], payload)
	if report[1] != 0x00 {
		return report, fmt.Errorf("keyboard reserved byte must be zero")
	}
	return report, nil
}

func ParseMousePayload(payload []byte) (MouseReport, error) {
	var report MouseReport
	if len(payload) != len(report) {
		return report, fmt.Errorf("mouse report must be %d bytes", len(report))
	}
	copy(report[:], payload)
	return report, nil
}
