package hid

import "context"

type Status struct {
	Backend   string `json:"backend"`
	Connected bool   `json:"connected"`
	Detail    string `json:"detail"`

	// Optional fields surfaced by backends that talk to a richer firmware
	// (currently just esp32-serial). They are pointers so they can be omitted
	// from the JSON status payload for backends that don't know these values.
	HidMounted          *bool  `json:"hid_mounted,omitempty"`
	BleEnabled          *bool  `json:"ble_enabled,omitempty"`
	BleClientConnected  *bool  `json:"ble_client_connected,omitempty"`
	FirmwareDeviceName  string `json:"firmware_device_name,omitempty"`
	FirmwareStateAgeMs  int64  `json:"firmware_state_age_ms,omitempty"`
}

type Backend interface {
	Name() string
	Open(ctx context.Context) error
	Close() error
	Status(ctx context.Context) Status
	SendKeyboardReport(ctx context.Context, report [8]byte) error
	SendMouseReport(ctx context.Context, report [4]byte) error
	Ping(ctx context.Context) error
}
