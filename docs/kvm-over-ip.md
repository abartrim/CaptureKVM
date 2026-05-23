# CaptureKVM over IP

CaptureKVM's remote mode keeps the existing local-first model and adds an optional Go agent for a Raspberry Pi or other Linux host.

## Architecture

- HDMI from the target goes into a UVC capture dongle on the Pi or Linux host.
- `capturekvm-agent` exposes the authenticated control plane over HTTP.
- Keyboard and mouse reports are sent over binary UDP.
- H.264 video is emitted over a separate UDP socket after the client authenticates with a `video_ping`.
- UDP payloads are protected with AES-256-GCM.
- Accepted input is forwarded either to the ESP32 serial bridge or to experimental `/dev/hidg*` gadget endpoints.

## Recommended baseline

- Ubuntu on Raspberry Pi 4 or newer
- Wired Ethernet
- A UVC capture dongle that can reliably do 720p60 or 1080p30 on the target you care about
- ESP32 serial backend for the first bring-up path

## Current implementation status

This repository now includes the first remote-mode slice:

- Go agent module under `agent/`
- control-plane HTTP API
- session negotiation
- encrypted UDP input transport
- authenticated UDP video sender and packetizer
- ESP32 serial backend
- ffmpeg-supervised H.264 Annex B encoder pipeline
- macOS remote-mode controls for agent URL/token plus encrypted UDP keyboard and mouse sends
- macOS UDP video receive, fragment reassembly, and H.264 sample-buffer rendering path

## Raspberry Pi setup

1. Install Go and build the agent from `agent/`.
2. Copy `agent/examples/config.example.yaml` to your target host and set a real auth token.
3. Point `hid.esp32_serial.port` at the ESP32 bridge serial device, usually `/dev/ttyACM0`.
4. Install `ffmpeg` if you want the built-in encoder command path.
5. Start `capturekvm-agent`.

For early smoke tests on a development machine, `--dev-insecure` defaults the HID backend to `mock` so you can exercise the control plane and UDP path before wiring the ESP32. The macOS client can now negotiate a remote session, send input over UDP, and listen for the agent's encrypted H.264 UDP preview stream.

## Why binary UDP

The local CaptureKVM path already prefers freshest-state-wins behavior:

- keyboard and mouse state are compact fixed-size reports
- the app drops late frames
- the firmware consumes simple binary reports directly

Binary UDP preserves that model better than WebSocket or MJPEG. It avoids extra text encoding, stream head-of-line blocking, and backpressure semantics on the hot path.

## Development workflow

Use the Raspberry Pi workspace as the primary environment for the Go agent, but the agent is intentionally buildable on other development hosts for protocol bring-up and smoke testing.
