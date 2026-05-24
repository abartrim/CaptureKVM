package hid

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type fakeSerialPort struct {
	writes  [][]byte
	readBuf []byte
	closed  bool
}

func (f *fakeSerialPort) Read(p []byte) (int, error) {
	if len(f.readBuf) == 0 {
		return 0, io.EOF
	}
	n := copy(p, f.readBuf[:1])
	f.readBuf = f.readBuf[n:]
	return n, nil
}

func (f *fakeSerialPort) Write(p []byte) (int, error) {
	cp := append([]byte(nil), p...)
	f.writes = append(f.writes, cp)
	return len(p), nil
}

func (f *fakeSerialPort) Close() error {
	f.closed = true
	return nil
}

func (f *fakeSerialPort) SetReadTimeout(time.Duration) error { return nil }
func (f *fakeSerialPort) ResetInputBuffer() error            { return nil }
func (f *fakeSerialPort) ResetOutputBuffer() error           { return nil }

func TestESP32SerialPingAndKeyboardFrame(t *testing.T) {
	fake := &fakeSerialPort{readBuf: []byte{pongByte}}
	backend, err := NewESP32Serial(ESP32SerialConfig{
		Port:          "/dev/fake",
		Baud:          921600,
		AutoReconnect: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	backend.openFn = func(name string, baud int) (serialPort, error) {
		if name != "/dev/fake" || baud != 921600 {
			t.Fatalf("unexpected open args %s %d", name, baud)
		}
		return fake, nil
	}

	if err := backend.Open(context.Background()); err != nil {
		t.Fatalf("open failed: %v", err)
	}
	if got, want := fake.writes[0], Frame(0x80, nil); string(got) != string(want) {
		t.Fatalf("unexpected ping frame: got %v want %v", got, want)
	}

	var report [8]byte
	report[2] = 0x04
	if err := backend.SendKeyboardReport(context.Background(), report); err != nil {
		t.Fatalf("send keyboard failed: %v", err)
	}
	if got, want := fake.writes[1], Frame(0x01, report[:]); string(got) != string(want) {
		t.Fatalf("unexpected keyboard frame: got %v want %v", got, want)
	}
}

func TestPiGadgetWritesReports(t *testing.T) {
	dir := t.TempDir()
	keyboardPath := filepath.Join(dir, "hidg0")
	mousePath := filepath.Join(dir, "hidg1")
	if err := os.WriteFile(keyboardPath, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(mousePath, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	backend := NewPiGadget(PiGadgetConfig{
		KeyboardPath: keyboardPath,
		MousePath:    mousePath,
	})
	if err := backend.Open(context.Background()); err != nil {
		t.Fatalf("open failed: %v", err)
	}
	defer backend.Close()

	if err := backend.SendKeyboardReport(context.Background(), [8]byte{0, 0, 4}); err != nil {
		t.Fatalf("send keyboard failed: %v", err)
	}
	if err := backend.SendMouseReport(context.Background(), [4]byte{1, 2, 3, 4}); err != nil {
		t.Fatalf("send mouse failed: %v", err)
	}

	keyboardData, err := os.ReadFile(keyboardPath)
	if err != nil {
		t.Fatal(err)
	}
	mouseData, err := os.ReadFile(mousePath)
	if err != nil {
		t.Fatal(err)
	}
	if len(keyboardData) != 8 {
		t.Fatalf("expected 8 keyboard bytes, got %d", len(keyboardData))
	}
	if len(mouseData) != 4 {
		t.Fatalf("expected 4 mouse bytes, got %d", len(mouseData))
	}
}
