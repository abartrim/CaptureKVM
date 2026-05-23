package hid

import (
	"context"
	"fmt"
	"log"
	"sync"
)

type MockBackend struct {
	logger     *log.Logger
	mu         sync.Mutex
	connected  bool
	keyboards  int
	mice       int
	lastDetail string
}

func NewMock(logger *log.Logger) *MockBackend {
	return &MockBackend{logger: logger}
}

func (m *MockBackend) Name() string { return "mock" }

func (m *MockBackend) Open(context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.connected = true
	m.lastDetail = "mock backend ready"
	return nil
}

func (m *MockBackend) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.connected = false
	return nil
}

func (m *MockBackend) Status(context.Context) Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	return Status{
		Backend:   m.Name(),
		Connected: m.connected,
		Detail:    m.lastDetail,
	}
}

func (m *MockBackend) SendKeyboardReport(_ context.Context, report [8]byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.connected {
		return fmt.Errorf("mock backend not connected")
	}
	m.keyboards++
	m.lastDetail = fmt.Sprintf("mock received %d keyboard reports", m.keyboards)
	if m.logger != nil {
		m.logger.Printf("mock keyboard report: % x", report)
	}
	return nil
}

func (m *MockBackend) SendMouseReport(_ context.Context, report [4]byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.connected {
		return fmt.Errorf("mock backend not connected")
	}
	m.mice++
	m.lastDetail = fmt.Sprintf("mock received %d mouse reports", m.mice)
	if m.logger != nil {
		m.logger.Printf("mock mouse report: % x", report)
	}
	return nil
}

func (m *MockBackend) Ping(context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.connected {
		return fmt.Errorf("mock backend not connected")
	}
	m.lastDetail = "mock ping ok"
	return nil
}
