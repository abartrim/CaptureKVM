package hid

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
	"time"

	"go.bug.st/serial"
)

const pongByte = 0xAA

type serialPort interface {
	io.ReadWriteCloser
	SetReadTimeout(time.Duration) error
	ResetInputBuffer() error
	ResetOutputBuffer() error
}

type serialOpener func(name string, baud int) (serialPort, error)

type ESP32SerialConfig struct {
	Port          string
	Baud          int
	AutoReconnect bool
	Logger        *log.Logger
}

type ESP32Serial struct {
	cfg    ESP32SerialConfig
	openFn serialOpener

	mu        sync.Mutex
	port      serialPort
	lastError string
}

func NewESP32Serial(cfg ESP32SerialConfig) (*ESP32Serial, error) {
	if cfg.Baud <= 0 {
		cfg.Baud = 921600
	}
	return &ESP32Serial{
		cfg:    cfg,
		openFn: openSerialPort,
	}, nil
}

func openSerialPort(name string, baud int) (serialPort, error) {
	mode := &serial.Mode{BaudRate: baud}
	port, err := serial.Open(name, mode)
	if err != nil {
		return nil, err
	}
	if err := port.SetReadTimeout(150 * time.Millisecond); err != nil {
		port.Close()
		return nil, err
	}
	return port, nil
}

func (e *ESP32Serial) Name() string { return "esp32-serial" }

func (e *ESP32Serial) Open(ctx context.Context) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.openLocked(ctx)
}

func (e *ESP32Serial) openLocked(ctx context.Context) error {
	if e.port != nil {
		return nil
	}
	if e.cfg.Port == "" {
		return errors.New("serial port is not configured")
	}
	port, err := e.openFn(e.cfg.Port, e.cfg.Baud)
	if err != nil {
		e.lastError = err.Error()
		return err
	}
	e.port = port
	e.lastError = ""
	if e.cfg.Logger != nil {
		e.cfg.Logger.Printf("esp32-serial connected: %s @ %d", e.cfg.Port, e.cfg.Baud)
	}
	if err := e.pingLocked(ctx); err != nil {
		_ = e.closeLocked()
		e.lastError = err.Error()
		return err
	}
	return nil
}

func (e *ESP32Serial) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.closeLocked()
}

func (e *ESP32Serial) closeLocked() error {
	if e.port == nil {
		return nil
	}
	err := e.port.Close()
	e.port = nil
	return err
}

func (e *ESP32Serial) Status(context.Context) Status {
	e.mu.Lock()
	defer e.mu.Unlock()
	detail := fmt.Sprintf("%s @ %d", e.cfg.Port, e.cfg.Baud)
	if e.lastError != "" {
		detail = e.lastError
	}
	return Status{
		Backend:   e.Name(),
		Connected: e.port != nil,
		Detail:    detail,
	}
}

func (e *ESP32Serial) SendKeyboardReport(ctx context.Context, report [8]byte) error {
	return e.writeFrame(ctx, 0x01, report[:])
}

func (e *ESP32Serial) SendMouseReport(ctx context.Context, report [4]byte) error {
	return e.writeFrame(ctx, 0x02, report[:])
}

func (e *ESP32Serial) Ping(ctx context.Context) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := e.ensureOpenLocked(ctx); err != nil {
		return err
	}
	return e.pingLocked(ctx)
}

func (e *ESP32Serial) writeFrame(ctx context.Context, frameType byte, payload []byte) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if err := e.ensureOpenLocked(ctx); err != nil {
		return err
	}

	if err := e.writeLocked(Frame(frameType, payload)); err != nil {
		e.lastError = err.Error()
		_ = e.closeLocked()
		return err
	}
	return nil
}

func (e *ESP32Serial) ensureOpenLocked(ctx context.Context) error {
	if e.port != nil {
		return nil
	}
	if !e.cfg.AutoReconnect {
		return errors.New("serial backend disconnected")
	}
	return e.openLocked(ctx)
}

func (e *ESP32Serial) writeLocked(frame []byte) error {
	if e.port == nil {
		return errors.New("serial backend disconnected")
	}
	_, err := e.port.Write(frame)
	return err
}

func (e *ESP32Serial) pingLocked(ctx context.Context) error {
	if e.port == nil {
		return errors.New("serial backend disconnected")
	}
	_ = e.port.ResetInputBuffer()
	_ = e.port.ResetOutputBuffer()
	if _, err := e.port.Write(Frame(0x80, nil)); err != nil {
		return err
	}

	buf := make([]byte, 1)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		n, err := e.port.Read(buf)
		if err != nil {
			if errors.Is(err, io.EOF) {
				continue
			}
			return err
		}
		if n == 1 && buf[0] == pongByte {
			return nil
		}
	}
}
