# CaptureKVM protocol notes

## ESP32 serial protocol

The existing ESP32 bridge protocol remains the compatibility anchor for the Go agent.

- Raw frame format: `[type][payload...][crc8]`
- CRC8 polynomial: `0x07`
- Stream framing: COBS-encode the raw frame, then append `0x00`
- HID frame types:
  - `0x01` keyboard boot report, payload length 8
  - `0x02` mouse boot report, payload length 4
  - `0x80` ping, empty payload, `0xAA` pong byte from firmware

The Go `esp32-serial` backend emits exactly that framing before writing to the serial port.

## Existing HID report model

CaptureKVM uses USB boot reports, not abstract key-up/key-down events:

- Keyboard: 8 bytes `[modifiers, reserved, k1, k2, k3, k4, k5, k6]`
- Mouse: 4 bytes `[buttons, dx, dy, wheel]`

The UDP input path reuses those same payloads so the remote model matches the local app and firmware path.

## UDP packet format

Each UDP datagram is one binary protocol packet:

| Field | Bytes |
| --- | ---: |
| magic (`CKVM`) | 4 |
| version | 1 |
| packet_kind | 1 |
| flags | 2 |
| session_id | 8 |
| seq | 4 |
| timestamp_us | 8 |
| payload_len | 2 |

The 30-byte clear header is authenticated as AEAD additional data.

Packet form on the wire is:

`clear_header || ciphertext || gcm_tag`

## UDP session crypto

v1 uses AES-256-GCM only.

- Session keys are created per session and returned over the authenticated HTTP control plane.
- The UDP header stays clear for simple routing and early rejection.
- Payloads are protected with AES-GCM.
- Nonces are 96-bit and derived from:
  - 7 bytes from the session ID
  - 1 byte direction
  - 4 bytes sequence number

Direction `0x01` is client-to-server and `0x02` is server-to-client.

## Input packet semantics

- `0x01` UDP packet kind: keyboard boot report payload
- `0x02` UDP packet kind: mouse boot report payload
- `0x03` UDP packet kind: ping

The receiver:

- checks header version and session membership
- rejects AES-GCM authentication failures before payload use
- keeps a per-session per-kind replay window
- forwards accepted keyboard and mouse payloads to the configured HID backend

## Video packet semantics

`video_ping` is the client's first UDP packet on the video socket. It has an empty payload and is authenticated with the session key. The agent uses its source address as the return path for video datagrams.

`video_config` payload is a fixed 20-byte binary structure:

| Offset | Field |
| --- | --- |
| 0 | codec (`0x01` = H.264) |
| 1 | format (`0x01` = Annex B) |
| 2..3 | width |
| 4..5 | height |
| 6..7 | fps |
| 8..11 | bitrate kbps |
| 12..13 | keyframe interval |
| 14 | hardware encode enabled |
| 15 | no B-frames enabled |

`video_frame` payload starts with a 12-byte fragment header:

| Offset | Field |
| --- | --- |
| 0..3 | frame_id |
| 4..7 | total_frame_bytes |
| 8..9 | fragment_index |
| 10..11 | fragment_count |

The remaining payload bytes are the Annex B fragment data for that frame. The packet header `flags` field uses bit 0 to mark keyframes.

## Session negotiation

`POST /api/session` returns:

- `session_id`
- `protocol_version`
- `expires_in_seconds`
- `crypto.session_key`
- `crypto.aad_header_bytes`
- UDP host and ports
- current video settings metadata

`POST /api/session/keepalive` refreshes the lease.

`POST /api/session/close` explicitly removes a session.

## Local serial/BLE vs remote UDP framing

- Serial and BLE are stream transports, so they use COBS + CRC8 framing.
- Remote UDP is datagram-native, so it does **not** use COBS and does **not** use CRC for security.
- The UDP layer carries the same fixed-size HID reports as the local path, and the agent translates them back into the existing ESP32 serial frame format when the `esp32-serial` backend is active.
