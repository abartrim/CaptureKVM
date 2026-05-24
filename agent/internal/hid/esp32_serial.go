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

const (
	pongByte                  = 0xAA
	frameTypeGetState         = 0x85
	statePollInterval         = 1 * time.Second
	pingResponseTimeout       = 300 * time.Millisecond
	getStatePayloadMinBytes   = 9 // ble_enabled(1) + hid_mounted(1) + ble_client(1) + pin(6)
	getStateBleEnabledOffset  = 0
	getStateHidMountedOffset  = 1
	getStateBleClientOffset   = 2
	getStateDeviceNameOffset  = 9
	maxIncomingCollectedBytes = 128
)

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

type firmwareState struct {
	bleEnabled         bool
	hidMounted         bool
	bleClientConnected bool
	deviceName         string
	lastUpdated        time.Time
}

type ESP32Serial struct {
	cfg    ESP32SerialConfig
	openFn serialOpener

	mu        sync.Mutex
	port      serialPort
	lastError string

	readerWg   sync.WaitGroup
	stopReader chan struct{}
	pollerStop chan struct{}

	stateMu sync.RWMutex
	state   firmwareState
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
	e.stopReader = make(chan struct{})
	e.pollerStop = make(chan struct{})

	if e.cfg.Logger != nil {
		e.cfg.Logger.Printf("esp32-serial connected: %s @ %d", e.cfg.Port, e.cfg.Baud)
	}

	// Verify the firmware is responsive BEFORE starting the background reader.
	// The firmware emits a lone 0xAA byte (no framing) in response to a ping;
	// once the reader is running, that byte gets absorbed into the running
	// frame collector along with any [BOOT]/[HB] text, so the only reliable
	// way to confirm the link is to do the initial ping with direct reads.
	if err := e.handshakePingLocked(ctx); err != nil {
		_ = e.closeLocked()
		e.lastError = err.Error()
		return err
	}

	// Start the persistent reader for ongoing GET_STATE responses and any
	// stray pong bytes (best-effort signal on pongCh).
	e.readerWg.Add(1)
	go e.readLoop(port, e.stopReader)

	// Kick off the periodic firmware-state poll so /api/status can report
	// whether the target machine has enumerated the ESP32's HID device.
	go e.statePollLoop(e.pollerStop)

	return nil
}

// handshakePingLocked writes a ping frame and reads bytes one at a time until
// it sees the pong byte. Boot/heartbeat ASCII text from the firmware is
// silently discarded. Runs only during Open, before the background reader is
// started — so it has exclusive access to the port.
func (e *ESP32Serial) handshakePingLocked(ctx context.Context) error {
	if e.port == nil {
		return errors.New("serial backend disconnected")
	}
	_ = e.port.ResetInputBuffer()
	_ = e.port.ResetOutputBuffer()
	if _, err := e.port.Write(Frame(0x80, nil)); err != nil {
		return err
	}
	deadline := time.Now().Add(pingResponseTimeout)
	buf := make([]byte, 1)
	for time.Now().Before(deadline) {
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
	return errors.New("timed out waiting for pong from ESP32")
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
	if e.stopReader != nil {
		close(e.stopReader)
		e.stopReader = nil
	}
	if e.pollerStop != nil {
		close(e.pollerStop)
		e.pollerStop = nil
	}
	err := e.port.Close()
	e.port = nil
	// Wait for the reader to exit so its log lines don't race after close.
	e.readerWg.Wait()
	return err
}

func (e *ESP32Serial) Status(context.Context) Status {
	e.mu.Lock()
	connected := e.port != nil
	detail := fmt.Sprintf("%s @ %d", e.cfg.Port, e.cfg.Baud)
	if e.lastError != "" {
		detail = e.lastError
	}
	e.mu.Unlock()

	status := Status{
		Backend:   e.Name(),
		Connected: connected,
		Detail:    detail,
	}

	e.stateMu.RLock()
	defer e.stateMu.RUnlock()
	if !e.state.lastUpdated.IsZero() {
		hidMounted := e.state.hidMounted
		bleEnabled := e.state.bleEnabled
		bleClient := e.state.bleClientConnected
		status.HidMounted = &hidMounted
		status.BleEnabled = &bleEnabled
		status.BleClientConnected = &bleClient
		status.FirmwareDeviceName = e.state.deviceName
		status.FirmwareStateAgeMs = time.Since(e.state.lastUpdated).Milliseconds()
	}
	return status
}

func (e *ESP32Serial) SendKeyboardReport(ctx context.Context, report [8]byte) error {
	return e.writeFrame(ctx, 0x01, report[:])
}

func (e *ESP32Serial) SendMouseReport(ctx context.Context, report [4]byte) error {
	return e.writeFrame(ctx, 0x02, report[:])
}

// Ping writes a framed ping to the ESP32. Once Open has succeeded the
// connection is known good; subsequent Ping calls (driven by the UDP input
// keepalive) are fire-and-forget — failure to write surfaces a serial error
// via the normal write path, while the firmware's one-byte pong response is
// absorbed by the background reader and discarded.
func (e *ESP32Serial) Ping(ctx context.Context) error {
	return e.writeFrame(ctx, 0x80, nil)
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

// readLoop continuously reads from the serial port, splits the stream into
// 0x00-delimited COBS frames, decodes them, and dispatches to:
//   - pongCh on a standalone pong byte (outside any frame),
//   - the cached firmware state on a GET_STATE response.
//
// Heartbeat/boot text from the firmware (e.g. "[HB] up=N..." or "[BOOT] ...")
// flows through this loop too; those bytes never contain 0x00 and so are
// silently accumulated and discarded when the collector overflows.
func (e *ESP32Serial) readLoop(port serialPort, stop <-chan struct{}) {
	defer e.readerWg.Done()

	var collector []byte
	buf := make([]byte, 64)
	for {
		select {
		case <-stop:
			return
		default:
		}
		n, err := port.Read(buf)
		if err != nil {
			// Common when the port is closed; just exit.
			return
		}
		for i := 0; i < n; i++ {
			b := buf[i]
			if b == 0x00 {
				if len(collector) > 0 {
					e.dispatchEncodedFrame(collector)
					collector = collector[:0]
				}
				continue
			}
			if len(collector) >= maxIncomingCollectedBytes {
				// Likely runaway log line; drop the accumulated bytes and resync
				// at the next 0x00 delimiter.
				collector = collector[:0]
				continue
			}
			collector = append(collector, b)
		}
	}
}

func (e *ESP32Serial) dispatchEncodedFrame(encoded []byte) {
	decoded := COBSDecode(encoded)
	if len(decoded) < 2 {
		return
	}
	body := decoded[:len(decoded)-1]
	crc := decoded[len(decoded)-1]
	if CRC8(body) != crc {
		return
	}
	frameType := body[0]
	payload := body[1:]
	switch frameType {
	case frameTypeGetState:
		if len(payload) < getStatePayloadMinBytes {
			return
		}
		name := ""
		if len(payload) > getStateDeviceNameOffset {
			name = string(payload[getStateDeviceNameOffset:])
		}
		e.stateMu.Lock()
		e.state.bleEnabled = payload[getStateBleEnabledOffset] != 0
		e.state.hidMounted = payload[getStateHidMountedOffset] != 0
		e.state.bleClientConnected = payload[getStateBleClientOffset] != 0
		e.state.deviceName = name
		e.state.lastUpdated = time.Now()
		e.stateMu.Unlock()
	}
}

func (e *ESP32Serial) statePollLoop(stop <-chan struct{}) {
	// Wait one tick before the first poll so callers that Open the backend and
	// then immediately send other frames (most notably unit tests) see a clean,
	// deterministic write stream. /api/status becomes useful after one tick.
	ticker := time.NewTicker(statePollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			e.requestStateBestEffort()
		}
	}
}

func (e *ESP32Serial) requestStateBestEffort() {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if err := e.writeFrame(ctx, frameTypeGetState, nil); err != nil && e.cfg.Logger != nil {
		e.cfg.Logger.Printf("esp32-serial state poll write failed: %v", err)
	}
}
