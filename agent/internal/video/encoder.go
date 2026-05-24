package video

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os/exec"
	"strconv"
	"strings"

	"github.com/abartrim/CaptureKVM/agent/internal/config"
)

type AccessUnit struct {
	Data     []byte
	Keyframe bool
}

type Encoder struct {
	cfg            config.VideoConfig
	logger         *log.Logger
	lookPath       func(string) (string, error)
	commandContext func(context.Context, string, ...string) *exec.Cmd
}

func NewEncoder(cfg config.VideoConfig, logger *log.Logger) *Encoder {
	return &Encoder{
		cfg:            cfg,
		logger:         logger,
		lookPath:       exec.LookPath,
		commandContext: exec.CommandContext,
	}
}

func (e *Encoder) Command() ([]string, error) {
	if len(e.cfg.EncoderCommand) > 0 {
		return append([]string(nil), e.cfg.EncoderCommand...), nil
	}

	codec := "libx264"
	if e.cfg.HardwareEncode {
		codec = "h264_v4l2m2m"
	}

	command := []string{
		"ffmpeg",
		"-hide_banner",
		"-loglevel", "warning",
		"-fflags", "+genpts+nobuffer",
		"-use_wallclock_as_timestamps", "1",
		"-f", "v4l2",
		"-framerate", strconv.Itoa(e.cfg.FPS),
		"-video_size", fmt.Sprintf("%dx%d", e.cfg.Width, e.cfg.Height),
		"-i", e.cfg.Source,
		"-an",
		"-c:v", codec,
		"-pix_fmt", "yuv420p",
		"-g", strconv.Itoa(e.cfg.KeyframeInterval),
		"-keyint_min", strconv.Itoa(e.cfg.KeyframeInterval),
		"-b:v", fmt.Sprintf("%dk", e.cfg.BitrateKbps),
		"-maxrate", fmt.Sprintf("%dk", e.cfg.BitrateKbps),
		"-bufsize", fmt.Sprintf("%dk", e.cfg.BitrateKbps*2),
		"-preset", "ultrafast",
		"-tune", "zerolatency",
	}
	if codec == "libx264" {
		command = append(command, "-x264-params", "repeat-headers=1")
	}
	command = append(command, "-bsf:v", strings.Join([]string{
		"dump_extra=freq=keyframe",
		"h264_metadata=aud=insert",
	}, ","))
	if e.cfg.NoBFrames {
		command = append(command, "-bf", "0")
	}
	command = append(command, "-f", "h264", "pipe:1")
	return command, nil
}

func (e *Encoder) Run(ctx context.Context, onAccessUnit func(AccessUnit) error) error {
	command, err := e.Command()
	if err != nil {
		return err
	}
	binaryPath, err := e.lookPath(command[0])
	if err != nil {
		return fmt.Errorf("find encoder %q: %w", command[0], err)
	}

	cmd := e.commandContext(ctx, binaryPath, command[1:]...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("stderr pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start encoder: %w", err)
	}

	if e.logger != nil {
		e.logger.Printf("video encoder started: %s", strings.Join(command, " "))
	}

	stderrDone := make(chan struct{})
	go func() {
		defer close(stderrDone)
		scanner := bufio.NewScanner(stderr)
		for scanner.Scan() {
			if e.logger != nil {
				e.logger.Printf("video encoder: %s", scanner.Text())
			}
		}
	}()

	parser := NewAnnexBParser(onAccessUnit)
	readErr := e.consumeStdout(stdout, parser)
	waitErr := cmd.Wait()
	<-stderrDone

	if readErr != nil && !errors.Is(readErr, context.Canceled) {
		return readErr
	}
	if waitErr != nil && !errors.Is(waitErr, context.Canceled) {
		return fmt.Errorf("encoder exited: %w", waitErr)
	}
	return ctx.Err()
}

func (e *Encoder) consumeStdout(stdout io.Reader, parser *AnnexBParser) error {
	buf := make([]byte, 32*1024)
	for {
		n, err := stdout.Read(buf)
		if n > 0 {
			if feedErr := parser.Feed(buf[:n]); feedErr != nil {
				return feedErr
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return parser.Flush()
			}
			return err
		}
	}
}

type AnnexBParser struct {
	buffer       []byte
	current      []byte
	currentKey   bool
	onAccessUnit func(AccessUnit) error
}

func NewAnnexBParser(onAccessUnit func(AccessUnit) error) *AnnexBParser {
	return &AnnexBParser{onAccessUnit: onAccessUnit}
}

func (p *AnnexBParser) Feed(data []byte) error {
	p.buffer = append(p.buffer, data...)
	return p.parse(false)
}

func (p *AnnexBParser) Flush() error {
	if err := p.parse(true); err != nil {
		return err
	}
	return p.emitCurrent()
}

func (p *AnnexBParser) parse(flush bool) error {
	for {
		start, _ := findStartCode(p.buffer, 0)
		if start < 0 {
			if !flush && len(p.buffer) > 4 {
				p.buffer = append([]byte(nil), p.buffer[len(p.buffer)-4:]...)
			}
			return nil
		}
		if start > 0 {
			p.buffer = append([]byte(nil), p.buffer[start:]...)
		}
		next, _ := findStartCode(p.buffer, 4)
		if next < 0 {
			if flush {
				unit := append([]byte(nil), p.buffer...)
				p.buffer = nil
				return p.consumeNAL(unit)
			}
			return nil
		}
		unit := append([]byte(nil), p.buffer[:next]...)
		p.buffer = append([]byte(nil), p.buffer[next:]...)
		if err := p.consumeNAL(unit); err != nil {
			return err
		}
	}
}

func (p *AnnexBParser) consumeNAL(unit []byte) error {
	nalType, ok := nalUnitType(unit)
	if !ok {
		return nil
	}
	if nalType == 9 && len(p.current) > 0 {
		if err := p.emitCurrent(); err != nil {
			return err
		}
	}
	p.current = append(p.current, unit...)
	if nalType == 5 {
		p.currentKey = true
	}
	return nil
}

func (p *AnnexBParser) emitCurrent() error {
	if len(p.current) == 0 {
		return nil
	}
	unit := AccessUnit{
		Data:     append([]byte(nil), p.current...),
		Keyframe: p.currentKey,
	}
	p.current = nil
	p.currentKey = false
	if p.onAccessUnit != nil {
		return p.onAccessUnit(unit)
	}
	return nil
}

func findStartCode(buf []byte, start int) (int, int) {
	for i := start; i+3 < len(buf); i++ {
		if buf[i] == 0x00 && buf[i+1] == 0x00 {
			if buf[i+2] == 0x01 {
				return i, 3
			}
			if i+3 < len(buf) && buf[i+2] == 0x00 && buf[i+3] == 0x01 {
				return i, 4
			}
		}
	}
	return -1, 0
}

func nalUnitType(unit []byte) (byte, bool) {
	idx, size := findStartCode(unit, 0)
	if idx < 0 || idx+size >= len(unit) {
		return 0, false
	}
	payload := bytes.TrimLeft(unit[idx+size:], "\x00")
	if len(payload) == 0 {
		return 0, false
	}
	return payload[0] & 0x1F, true
}
