# capturekvm-agent

`capturekvm-agent` is the new Go control-plane and UDP transport service for CaptureKVM's optional KVM-over-IP mode.

This initial implementation covers:

- HTTP control plane with token auth, status, session create, keepalive, close, and video source reporting.
- Fixed-header UDP packet/session layer protected with AES-256-GCM.
- UDP input receiver that accepts CaptureKVM keyboard, mouse, and ping packets.
- UDP video socket that authenticates `video_ping`, learns client peers, and packetizes encrypted H.264 Annex B fragments.
- External encoder supervision for an ffmpeg-based low-latency H.264 pipeline.
- HID backends for mock, ESP32 serial, and experimental Pi gadget endpoints.

The macOS remote client is still pending, but the agent now has a concrete server-side video transport path instead of only stubs.
