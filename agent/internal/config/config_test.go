package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadAppliesDefaultsAndFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(path, []byte(`
auth:
  token: "test-token"
hid:
  backend: "mock"
video:
  source: "/dev/video9"
`), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(path, false)
	if err != nil {
		t.Fatalf("load failed: %v", err)
	}
	if cfg.Auth.Token != "test-token" {
		t.Fatalf("expected token from file, got %q", cfg.Auth.Token)
	}
	if cfg.HID.Backend != "mock" {
		t.Fatalf("expected mock backend, got %q", cfg.HID.Backend)
	}
	if cfg.HID.ESP32Serial.Baud != DefaultSerialBaud {
		t.Fatalf("expected serial baud default, got %d", cfg.HID.ESP32Serial.Baud)
	}
}

func TestLoadAppliesEnvironmentOverrides(t *testing.T) {
	t.Setenv("CAPTUREKVM_AUTH_TOKEN", "env-token")
	t.Setenv("CAPTUREKVM_HID_BACKEND", "mock")

	cfg, err := Load("", false)
	if err != nil {
		t.Fatalf("load failed: %v", err)
	}
	if cfg.Auth.Token != "env-token" {
		t.Fatalf("expected env token, got %q", cfg.Auth.Token)
	}
	if cfg.HID.Backend != "mock" {
		t.Fatalf("expected env backend override, got %q", cfg.HID.Backend)
	}
}

func TestLoadRejectsMissingTokenWithoutDevMode(t *testing.T) {
	if _, err := Load("", false); err == nil {
		t.Fatal("expected missing token error")
	}
}

func TestLoadAllowsDevInsecureMockDefaults(t *testing.T) {
	cfg, err := Load("", true)
	if err != nil {
		t.Fatalf("load failed: %v", err)
	}
	if cfg.HID.Backend != "mock" {
		t.Fatalf("expected mock backend in dev mode, got %q", cfg.HID.Backend)
	}
}
