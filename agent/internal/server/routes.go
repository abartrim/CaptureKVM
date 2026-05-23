package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/abartrim/CaptureKVM/agent/internal/auth"
	"github.com/abartrim/CaptureKVM/agent/internal/control"
	"github.com/abartrim/CaptureKVM/agent/internal/udp"
)

type sessionRequest struct {
	SessionID string `json:"session_id"`
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)

	protected := http.NewServeMux()
	protected.HandleFunc("GET /api/status", s.handleStatus)
	protected.HandleFunc("POST /api/session", s.handleCreateSession)
	protected.HandleFunc("POST /api/session/keepalive", s.handleKeepAlive)
	protected.HandleFunc("POST /api/session/close", s.handleCloseSession)
	protected.HandleFunc("GET /api/video/source", s.handleVideoSource)

	if s.cfg.DevInsecure && s.cfg.Auth.Token == "" {
		mux.Handle("/", protected)
	} else {
		mux.Handle("/", auth.Middleware(s.cfg.Auth.Token, protected))
	}
	return mux
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{
		OK:      true,
		Service: "capturekvm-agent",
		Version: s.version,
		Time:    time.Now().UTC(),
	})
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	hidStatus := s.backend.Status(r.Context())
	writeJSON(w, http.StatusOK, statusResponse{
		OK:      true,
		Version: s.version,
		UDP: udpStatus{
			Enabled:   true,
			InputPort: s.cfg.UDP.InputPort,
			VideoPort: s.cfg.UDP.VideoPort,
			MTU:       s.cfg.UDP.MTU,
			Stats:     s.inputReceiver.Status().Counters,
		},
		Video: videoState{
			Codec:   s.cfg.Video.Codec,
			Width:   s.cfg.Video.Width,
			Height:  s.cfg.Video.Height,
			FPS:     s.cfg.Video.FPS,
			Healthy: s.videoStream.Status().Healthy,
		},
		HID:  hidStatus,
		Auth: authState{Enabled: !s.cfg.DevInsecure},
	})
}

func (s *Server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	session, err := s.sessions.Create()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":                 true,
		"session_id":         session.IDString(),
		"protocol_version":   udp.ProtocolVersion,
		"expires_in_seconds": s.cfg.Auth.SessionTTLSeconds,
		"crypto": map[string]any{
			"udp_suite":        s.cfg.Crypto.UDPSuite,
			"key_bytes":        s.cfg.Crypto.KeyBytes,
			"nonce_bytes":      s.cfg.Crypto.NonceBytes,
			"session_key":      session.KeyBase64(),
			"aad_header_bytes": udp.HeaderSize,
		},
		"udp": map[string]any{
			"host":       s.cfg.UDP.PublicHost,
			"input_port": s.cfg.UDP.InputPort,
			"video_port": s.cfg.UDP.VideoPort,
			"mtu":        s.cfg.UDP.MTU,
		},
		"video": map[string]any{
			"codec":  s.cfg.Video.Codec,
			"width":  s.cfg.Video.Width,
			"height": s.cfg.Video.Height,
			"fps":    s.cfg.Video.FPS,
			"format": "annexb",
		},
	})
}

func (s *Server) handleKeepAlive(w http.ResponseWriter, r *http.Request) {
	var req sessionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	id, err := control.ParseSessionID(req.SessionID)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	session, err := s.sessions.KeepAlive(id)
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, control.ErrSessionNotFound) {
			status = http.StatusNotFound
		}
		writeError(w, status, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":                 true,
		"session_id":         session.IDString(),
		"expires_in_seconds": s.cfg.Auth.SessionTTLSeconds,
	})
}

func (s *Server) handleCloseSession(w http.ResponseWriter, r *http.Request) {
	var req sessionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	id, err := control.ParseSessionID(req.SessionID)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"closed":  s.sessions.Close(id),
		"session": req.SessionID,
	})
}

func (s *Server) handleVideoSource(w http.ResponseWriter, _ *http.Request) {
	status := s.videoStream.Status()
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true,
		"video": map[string]any{
			"source":            s.cfg.Video.Source,
			"codec":             s.cfg.Video.Codec,
			"width":             s.cfg.Video.Width,
			"height":            s.cfg.Video.Height,
			"fps":               s.cfg.Video.FPS,
			"bitrate_kbps":      s.cfg.Video.BitrateKbps,
			"keyframe_interval": s.cfg.Video.KeyframeInterval,
			"hardware_encode":   s.cfg.Video.HardwareEncode,
			"no_b_frames":       s.cfg.Video.NoBFrames,
			"healthy":           status.Healthy,
			"detail":            status.Detail,
		},
	})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]any{
		"ok":    false,
		"error": err.Error(),
	})
}
