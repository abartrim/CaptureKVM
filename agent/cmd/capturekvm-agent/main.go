package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
	"github.com/abartrim/CaptureKVM/agent/internal/control"
	"github.com/abartrim/CaptureKVM/agent/internal/hid"
	"github.com/abartrim/CaptureKVM/agent/internal/server"
	"github.com/abartrim/CaptureKVM/agent/internal/udp"
	"github.com/abartrim/CaptureKVM/agent/internal/video"
	"golang.org/x/sys/cpu"
)

const version = "0.1.0"

func main() {
	var (
		configPath  string
		devInsecure bool
	)

	flag.StringVar(&configPath, "config", "", "path to YAML or JSON config")
	flag.BoolVar(&devInsecure, "dev-insecure", false, "allow startup without auth token; defaults HID backend to mock")
	flag.Parse()

	logger := log.New(os.Stdout, "capturekvm-agent: ", log.LstdFlags|log.Lmicroseconds)

	cfg, err := config.Load(configPath, devInsecure)
	if err != nil {
		logger.Fatalf("load config: %v", err)
	}

	logCryptoCapabilities(logger)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	backend, err := newBackend(cfg, logger)
	if err != nil {
		logger.Fatalf("build HID backend: %v", err)
	}
	if err := backend.Open(ctx); err != nil {
		logger.Fatalf("open HID backend: %v", err)
	}
	defer backend.Close()

	sessions := control.NewManager(time.Duration(cfg.Auth.SessionTTLSeconds) * time.Second)
	videoStream := video.NewStream(cfg.Video)
	inputReceiver, err := udp.NewInputReceiver(cfg.UDP, sessions, backend, logger)
	if err != nil {
		logger.Fatalf("create UDP input receiver: %v", err)
	}

	srv := server.New(cfg, version, backend, sessions, inputReceiver, videoStream, logger)
	if err := inputReceiver.Start(ctx); err != nil {
		logger.Fatalf("start UDP input receiver: %v", err)
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, context.Canceled) {
			logger.Printf("shutdown: %v", err)
		}
	}()

	logger.Printf("starting control plane on %s", cfg.Server.Bind)
	if err := srv.Run(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatalf("server failed: %v", err)
	}
}

func newBackend(cfg config.Config, logger *log.Logger) (hid.Backend, error) {
	switch cfg.HID.Backend {
	case "mock":
		return hid.NewMock(logger), nil
	case "esp32-serial":
		return hid.NewESP32Serial(hid.ESP32SerialConfig{
			Port:          cfg.HID.ESP32Serial.Port,
			Baud:          cfg.HID.ESP32Serial.Baud,
			AutoReconnect: cfg.HID.ESP32Serial.AutoReconnect,
			Logger:        logger,
		})
	case "pi-gadget":
		return hid.NewPiGadget(hid.PiGadgetConfig{
			KeyboardPath: cfg.HID.PiGadget.Keyboard,
			MousePath:    cfg.HID.PiGadget.Mouse,
		}), nil
	default:
		return nil, errors.New("unsupported HID backend: " + cfg.HID.Backend)
	}
}

func logCryptoCapabilities(logger *log.Logger) {
	switch runtime.GOARCH {
	case "arm64":
		logger.Printf("cpu features: arm64 aes=%t pmull=%t", cpu.ARM64.HasAES, cpu.ARM64.HasPMULL)
	case "amd64":
		logger.Printf("cpu features: amd64 aes=%t pclmulqdq=%t", cpu.X86.HasAES, cpu.X86.HasPCLMULQDQ)
	default:
		logger.Printf("cpu features: arch=%s hardware AES detection unavailable", runtime.GOARCH)
	}
}
