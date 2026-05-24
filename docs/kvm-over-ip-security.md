# CaptureKVM over IP security

KVM-over-IP exposes privileged remote control of the target machine. Treat it as sensitive infrastructure.

## Practical guidance

- Do **not** expose `capturekvm-agent` directly to the public internet.
- Require an auth token for the HTTP control plane.
- Prefer a trusted LAN, WireGuard, Tailscale, or another VPN.
- Consider a dedicated VLAN for management hardware.
- Clipboard paste is equivalent to typing commands directly on the target.
- UDP session keys are short-lived and negotiated over the authenticated control plane.

## UDP protection

v1 protects UDP payloads with AES-256-GCM.

- The packet header remains clear for routing and parsing.
- That clear header is authenticated as AEAD additional data.
- Packets with invalid tags are rejected before payload processing.
- Replay and stale packets are rejected inside the active-session window.

On macOS the matching client-side implementation can use CryptoKit AES-GCM directly. On Ubuntu arm64 Raspberry Pi deployments, AES and PMULL capability should be detected and logged rather than assumed.

This is a practical remote-control feature, not a certified secure KVM platform.
