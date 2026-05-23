# capturekvm-agent

`capturekvm-agent` is the new Go control-plane and UDP transport service for CaptureKVM's optional KVM-over-IP mode.

This initial implementation covers:

- HTTP control plane with token auth, status, session create, keepalive, close, and video source reporting.
- Fixed-header UDP packet/session layer protected with AES-256-GCM.
- UDP input receiver that accepts CaptureKVM keyboard, mouse, and ping packets.
- HID backends for mock, ESP32 serial, and experimental Pi gadget endpoints.

The low-latency remote video sender is intentionally still skeletal in this slice; the current focus is getting the authenticated session, encrypted input path, and ESP32 compatibility layer in place first.
