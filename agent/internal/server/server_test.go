package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
	"github.com/abartrim/CaptureKVM/agent/internal/control"
	"github.com/abartrim/CaptureKVM/agent/internal/hid"
	"github.com/abartrim/CaptureKVM/agent/internal/udp"
	"github.com/abartrim/CaptureKVM/agent/internal/video"
)

func newTestServer(t *testing.T) *Server {
	t.Helper()
	cfg := config.Default(false)
	cfg.Auth.Token = "secret"
	cfg.HID.Backend = "mock"
	backend := hid.NewMock(nil)
	if err := backend.Open(context.Background()); err != nil {
		t.Fatal(err)
	}
	sessions := control.NewManager(time.Minute)
	videoStream := video.NewStream(cfg.Video, nil)
	inputReceiver, err := udp.NewInputReceiver(cfg.UDP, sessions, backend, nil)
	if err != nil {
		t.Fatal(err)
	}
	videoSender, err := udp.NewVideoSender(cfg.UDP, cfg.Video, sessions, videoStream, nil)
	if err != nil {
		t.Fatal(err)
	}
	return New(cfg, "test", backend, sessions, inputReceiver, videoSender, videoStream, nil)
}

func TestHealthEndpoint(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)

	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestStatusRequiresAuth(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)

	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestSessionCreateAndKeepAlive(t *testing.T) {
	srv := newTestServer(t)

	createReq := httptest.NewRequest(http.MethodPost, "/api/session", nil)
	createReq.Header.Set("Authorization", "Bearer secret")
	createRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(createRec, createReq)
	if createRec.Code != http.StatusOK {
		t.Fatalf("create session status=%d body=%s", createRec.Code, createRec.Body.String())
	}

	var createResp struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(createRec.Body.Bytes(), &createResp); err != nil {
		t.Fatal(err)
	}

	body, _ := json.Marshal(map[string]string{"session_id": createResp.SessionID})
	keepaliveReq := httptest.NewRequest(http.MethodPost, "/api/session/keepalive", bytes.NewReader(body))
	keepaliveReq.Header.Set("Authorization", "Bearer secret")
	keepaliveRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(keepaliveRec, keepaliveReq)
	if keepaliveRec.Code != http.StatusOK {
		t.Fatalf("keepalive status=%d body=%s", keepaliveRec.Code, keepaliveRec.Body.String())
	}
}
