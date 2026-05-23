package config

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	DefaultMTU         = 1200
	DefaultSessionTTL  = 60
	DefaultSerialBaud  = 921600
	DefaultProtocol    = "AES-256-GCM"
	DefaultInputPort   = 8091
	DefaultVideoPort   = 8092
	DefaultControlBind = "0.0.0.0:8080"
	DefaultUDPBind     = "0.0.0.0:8090"
)

type Config struct {
	Server      ServerConfig  `yaml:"server" json:"server"`
	Auth        AuthConfig    `yaml:"auth" json:"auth"`
	Crypto      CryptoConfig  `yaml:"crypto" json:"crypto"`
	UDP         UDPConfig     `yaml:"udp" json:"udp"`
	Video       VideoConfig   `yaml:"video" json:"video"`
	HID         HIDConfig     `yaml:"hid" json:"hid"`
	Logging     LoggingConfig `yaml:"logging" json:"logging"`
	DevInsecure bool          `yaml:"-" json:"-"`
}

type ServerConfig struct {
	Bind          string `yaml:"bind" json:"bind"`
	PublicBaseURL string `yaml:"public_base_url" json:"public_base_url"`
}

type AuthConfig struct {
	Token             string `yaml:"token" json:"token"`
	SessionTTLSeconds int    `yaml:"session_ttl_seconds" json:"session_ttl_seconds"`
}

type CryptoConfig struct {
	UDPSuite   string `yaml:"udp_suite" json:"udp_suite"`
	KeyBytes   int    `yaml:"key_bytes" json:"key_bytes"`
	NonceBytes int    `yaml:"nonce_bytes" json:"nonce_bytes"`
}

type UDPConfig struct {
	Bind             string `yaml:"bind" json:"bind"`
	PublicHost       string `yaml:"public_host" json:"public_host"`
	InputPort        int    `yaml:"input_port" json:"input_port"`
	VideoPort        int    `yaml:"video_port" json:"video_port"`
	MTU              int    `yaml:"mtu" json:"mtu"`
	MaxReorderFrames int    `yaml:"max_reorder_frames" json:"max_reorder_frames"`
}

type VideoConfig struct {
	Source           string `yaml:"source" json:"source"`
	Codec            string `yaml:"codec" json:"codec"`
	Width            int    `yaml:"width" json:"width"`
	Height           int    `yaml:"height" json:"height"`
	FPS              int    `yaml:"fps" json:"fps"`
	BitrateKbps      int    `yaml:"bitrate_kbps" json:"bitrate_kbps"`
	KeyframeInterval int    `yaml:"keyframe_interval" json:"keyframe_interval"`
	HardwareEncode   bool   `yaml:"hardware_encode" json:"hardware_encode"`
	NoBFrames        bool   `yaml:"no_b_frames" json:"no_b_frames"`
}

type HIDConfig struct {
	Backend     string            `yaml:"backend" json:"backend"`
	ESP32Serial ESP32SerialConfig `yaml:"esp32_serial" json:"esp32_serial"`
	PiGadget    PiGadgetConfig    `yaml:"pi_gadget" json:"pi_gadget"`
}

type ESP32SerialConfig struct {
	Port          string `yaml:"port" json:"port"`
	Baud          int    `yaml:"baud" json:"baud"`
	AutoReconnect bool   `yaml:"auto_reconnect" json:"auto_reconnect"`
}

type PiGadgetConfig struct {
	Keyboard string `yaml:"keyboard" json:"keyboard"`
	Mouse    string `yaml:"mouse" json:"mouse"`
}

type LoggingConfig struct {
	Level string `yaml:"level" json:"level"`
}

func Default(devInsecure bool) Config {
	backend := "esp32-serial"
	if devInsecure {
		backend = "mock"
	}

	return Config{
		Server: ServerConfig{
			Bind:          DefaultControlBind,
			PublicBaseURL: "http://capturekvm.local:8080",
		},
		Auth: AuthConfig{
			SessionTTLSeconds: DefaultSessionTTL,
		},
		Crypto: CryptoConfig{
			UDPSuite:   DefaultProtocol,
			KeyBytes:   32,
			NonceBytes: 12,
		},
		UDP: UDPConfig{
			Bind:             DefaultUDPBind,
			PublicHost:       "capturekvm.local",
			InputPort:        DefaultInputPort,
			VideoPort:        DefaultVideoPort,
			MTU:              DefaultMTU,
			MaxReorderFrames: 2,
		},
		Video: VideoConfig{
			Source:           "/dev/video0",
			Codec:            "h264",
			Width:            1280,
			Height:           720,
			FPS:              60,
			BitrateKbps:      6000,
			KeyframeInterval: 30,
			HardwareEncode:   true,
			NoBFrames:        true,
		},
		HID: HIDConfig{
			Backend: backend,
			ESP32Serial: ESP32SerialConfig{
				Baud:          DefaultSerialBaud,
				AutoReconnect: true,
			},
			PiGadget: PiGadgetConfig{
				Keyboard: "/dev/hidg0",
				Mouse:    "/dev/hidg1",
			},
		},
		Logging:     LoggingConfig{Level: "info"},
		DevInsecure: devInsecure,
	}
}

func Load(path string, devInsecure bool) (Config, error) {
	cfg := Default(devInsecure)

	if path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return Config{}, fmt.Errorf("read config: %w", err)
		}
		if err := yaml.Unmarshal(data, &cfg); err != nil {
			return Config{}, fmt.Errorf("parse config: %w", err)
		}
	}

	cfg.DevInsecure = devInsecure
	applyEnvOverrides(&cfg)

	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}

	return cfg, nil
}

func (c Config) Validate() error {
	if strings.TrimSpace(c.Server.Bind) == "" {
		return errors.New("server.bind is required")
	}
	if strings.TrimSpace(c.UDP.Bind) == "" {
		return errors.New("udp.bind is required")
	}
	if !c.DevInsecure && strings.TrimSpace(c.Auth.Token) == "" {
		return errors.New("auth.token is required unless --dev-insecure is set")
	}
	if c.Auth.SessionTTLSeconds <= 0 {
		return errors.New("auth.session_ttl_seconds must be positive")
	}
	if c.Crypto.UDPSuite != DefaultProtocol {
		return fmt.Errorf("unsupported crypto.udp_suite %q", c.Crypto.UDPSuite)
	}
	if c.Crypto.KeyBytes != 32 {
		return errors.New("crypto.key_bytes must be 32 for AES-256-GCM")
	}
	if c.Crypto.NonceBytes != 12 {
		return errors.New("crypto.nonce_bytes must be 12 for AES-GCM")
	}
	if c.UDP.MTU < 256 {
		return errors.New("udp.mtu must be at least 256")
	}
	if c.UDP.InputPort <= 0 || c.UDP.VideoPort <= 0 {
		return errors.New("udp input/video ports must be positive")
	}
	switch c.HID.Backend {
	case "mock":
	case "esp32-serial":
		if strings.TrimSpace(c.HID.ESP32Serial.Port) == "" && !c.DevInsecure {
			return errors.New("hid.esp32_serial.port is required for esp32-serial backend")
		}
		if c.HID.ESP32Serial.Baud <= 0 {
			return errors.New("hid.esp32_serial.baud must be positive")
		}
	case "pi-gadget":
		if strings.TrimSpace(c.HID.PiGadget.Keyboard) == "" || strings.TrimSpace(c.HID.PiGadget.Mouse) == "" {
			return errors.New("hid.pi_gadget keyboard and mouse endpoints are required")
		}
	default:
		return fmt.Errorf("unsupported hid.backend %q", c.HID.Backend)
	}
	return nil
}

func (c UDPConfig) ListenHost() string {
	host, _, err := net.SplitHostPort(c.Bind)
	if err == nil {
		return host
	}
	return c.Bind
}

func (c UDPConfig) InputListenAddr() string {
	return net.JoinHostPort(c.ListenHost(), strconv.Itoa(c.InputPort))
}

func (c UDPConfig) VideoListenAddr() string {
	return net.JoinHostPort(c.ListenHost(), strconv.Itoa(c.VideoPort))
}

func applyEnvOverrides(cfg *Config) {
	overrideString(&cfg.Server.Bind, "CAPTUREKVM_BIND")
	overrideString(&cfg.Auth.Token, "CAPTUREKVM_AUTH_TOKEN")
	overrideString(&cfg.UDP.Bind, "CAPTUREKVM_UDP_BIND")
	overrideString(&cfg.UDP.PublicHost, "CAPTUREKVM_UDP_PUBLIC_HOST")
	overrideString(&cfg.HID.Backend, "CAPTUREKVM_HID_BACKEND")
	overrideString(&cfg.HID.ESP32Serial.Port, "CAPTUREKVM_SERIAL_PORT")
	overrideString(&cfg.Video.Source, "CAPTUREKVM_VIDEO_SOURCE")
}

func overrideString(target *string, envKey string) {
	if value, ok := os.LookupEnv(envKey); ok {
		*target = value
	}
}
