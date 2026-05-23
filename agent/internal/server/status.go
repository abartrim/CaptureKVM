package server

import (
	"time"

	"github.com/abartrim/CaptureKVM/agent/internal/hid"
)

type healthResponse struct {
	OK      bool      `json:"ok"`
	Service string    `json:"service"`
	Version string    `json:"version"`
	Time    time.Time `json:"time"`
}

type statusResponse struct {
	OK      bool       `json:"ok"`
	Version string     `json:"version"`
	UDP     udpStatus  `json:"udp"`
	Video   videoState `json:"video"`
	HID     hid.Status `json:"hid"`
	Auth    authState  `json:"auth"`
}

type udpStatus struct {
	Enabled   bool              `json:"enabled"`
	InputPort int               `json:"input_port"`
	VideoPort int               `json:"video_port"`
	MTU       int               `json:"mtu"`
	Stats     map[string]uint64 `json:"stats,omitempty"`
}

type videoState struct {
	Codec   string `json:"codec"`
	Width   int    `json:"width"`
	Height  int    `json:"height"`
	FPS     int    `json:"fps"`
	Healthy bool   `json:"healthy"`
}

type authState struct {
	Enabled bool `json:"enabled"`
}
