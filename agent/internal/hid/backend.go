package hid

import "context"

type Status struct {
	Backend   string `json:"backend"`
	Connected bool   `json:"connected"`
	Detail    string `json:"detail"`
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
