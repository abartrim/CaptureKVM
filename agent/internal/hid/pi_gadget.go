package hid

import (
	"context"
	"fmt"
	"os"
	"sync"
)

type PiGadgetConfig struct {
	KeyboardPath string
	MousePath    string
}

type PiGadget struct {
	cfg PiGadgetConfig

	mu       sync.Mutex
	keyboard *os.File
	mouse    *os.File
}

func NewPiGadget(cfg PiGadgetConfig) *PiGadget {
	return &PiGadget{cfg: cfg}
}

func (p *PiGadget) Name() string { return "pi-gadget" }

func (p *PiGadget) Open(context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	keyboard, err := os.OpenFile(p.cfg.KeyboardPath, os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("open keyboard gadget %q: %w", p.cfg.KeyboardPath, err)
	}
	mouse, err := os.OpenFile(p.cfg.MousePath, os.O_WRONLY, 0)
	if err != nil {
		_ = keyboard.Close()
		return fmt.Errorf("open mouse gadget %q: %w", p.cfg.MousePath, err)
	}
	p.keyboard = keyboard
	p.mouse = mouse
	return nil
}

func (p *PiGadget) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.keyboard != nil {
		_ = p.keyboard.Close()
		p.keyboard = nil
	}
	if p.mouse != nil {
		_ = p.mouse.Close()
		p.mouse = nil
	}
	return nil
}

func (p *PiGadget) Status(context.Context) Status {
	p.mu.Lock()
	defer p.mu.Unlock()
	return Status{
		Backend:   p.Name(),
		Connected: p.keyboard != nil && p.mouse != nil,
		Detail:    fmt.Sprintf("keyboard=%s mouse=%s", p.cfg.KeyboardPath, p.cfg.MousePath),
	}
}

func (p *PiGadget) SendKeyboardReport(_ context.Context, report [8]byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.keyboard == nil {
		return fmt.Errorf("keyboard gadget is not open")
	}
	_, err := p.keyboard.Write(report[:])
	return err
}

func (p *PiGadget) SendMouseReport(_ context.Context, report [4]byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.mouse == nil {
		return fmt.Errorf("mouse gadget is not open")
	}
	_, err := p.mouse.Write(report[:])
	return err
}

func (p *PiGadget) Ping(context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.keyboard == nil || p.mouse == nil {
		return fmt.Errorf("pi-gadget backend is not open")
	}
	return nil
}
