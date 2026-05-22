# CaptureKVM

A do-it-yourself KVM solution for headless or remote machines, built around a USB-C video capture card and an ESP32-S3 acting as a USB HID bridge. CaptureKVM is the macOS app on the host side. `ESP32KVMFirmware/` is the firmware that runs on the bridge board.

## What it does

You can see and control a target machine from your Mac:

- **See** — the target's HDMI/DisplayPort output is fed into a USB-C capture card on the host Mac. The app displays it as a live preview.
- **Control** — your host's keyboard and mouse events are forwarded over a serial link to an ESP32, which re-emits them to the target as a USB HID keyboard and mouse.

It works for BIOS / pre-OS screens, headless servers, locked machines, and any OS the target runs.

## Architecture

```
+------------------+                           +----------------+
| Target machine   |--- HDMI / DisplayPort --->| USB-C capture  |---+
| (Linux / Mac /   |                           | card           |   |
|  Windows / BIOS) |                           +----------------+   |
|                  |                                                |  USB-C
|                  |<--- USB HID (keyboard +                        |
|                  |     mouse) -------------+                      |
+------------------+                         |                      |
                                             |                      v
                              +--------------+--------------+   +---------+
                              | ESP32-S3 "USB" port         |   |  Host   |
                              | (native USB OTG, TinyUSB)   |   |  Mac    |
                              |                             |   |         |
                              |  Reads UART0, decodes COBS  |   | runs    |
                              |  + CRC8 frames, emits HID   |   | Capture |
                              |  reports.                   |   | KVM.app |
                              |                             |   |         |
                              | ESP32-S3 "COM" port         |<--+         |
                              | (UART bridge chip)          |   |         |
                              +-----------------------------+   +---------+
                                                                     ^
                                       host keyboard + mouse ---------+
```

Two USB cables run between the Mac and the ESP32-S3 dev kit:

- The **"COM"** USB-C is the bridge chip (CP2102N or CH343) that exposes UART0 as a virtual serial port on the Mac. The Mac app sends framed control packets over it.
- The **"USB"** USB-C is the ESP32-S3's native USB OTG. It's plugged into the **target machine** (not the Mac), where it enumerates as a USB HID keyboard + mouse.

A third USB connection — the USB-C capture card — also runs from the target's video output to the host Mac.

## Wire protocol (host → ESP32)

Each frame is:

```
[type byte][payload bytes...][CRC8 trailer]   <- raw frame
COBS-encode the whole thing, append 0x00.    <- on the wire
```

- CRC8 polynomial `0x07` (the same one TinyUSB uses for its scratchpads — easy to verify on either end).
- COBS keeps the byte stream `0x00`-free so the trailing `0x00` is an unambiguous delimiter.

Two frame types are currently defined:

| Type | Meaning             | Payload                                                     |
| ---- | ------------------- | ----------------------------------------------------------- |
| 0x01 | Boot keyboard report | `[modifiers, reserved=0, k1, k2, k3, k4, k5, k6]` (8 bytes) |
| 0x02 | Boot mouse report    | `[buttons, dx, dy, wheel_vert]` (4 bytes; dx/dy/wheel are int8) |

The encoder/decoder lives in `CaptureKVM/HIDEncoder.swift` and `ESP32KVMFirmware/ESP32KVMFirmware.ino`.

## Repository layout

```
CaptureKVM.xcodeproj/       Xcode project for the macOS app.
CaptureKVM/                 macOS app sources.
  AppModel.swift              Top-level model: device enumeration, hot-plug,
                              input handling, paste-from-host, frame dispatch.
  CaptureManager.swift        AVFoundation session for the USB-C capture card.
  ESP32Serial.swift           Serial port enumeration + open + send (POSIX termios).
  HIDEncoder.swift            COBS + CRC8 framing; US keyCode -> HID usage map;
                              US character -> HID usage map for paste.
  InputForwarderView.swift    Transparent NSView that intercepts keyboard / mouse
                              events; cursor hide + warp + decoupling.
  ContentView.swift           SwiftUI toolbar + preview + status.
  CaptureKVM.entitlements     App sandbox + device entitlements (camera, USB,
                              bluetooth, network, /dev/cu.* exception).
ESP32KVMFirmware/           Arduino sketch for the ESP32-S3.
  ESP32KVMFirmware.ino
```

## Hardware bill of materials

| Item                                                | Notes                                                                       |
| --------------------------------------------------- | --------------------------------------------------------------------------- |
| ESP32-S3-DevKitC "Dual Type-C" (any 4-16 MB flash variant) | Two USB-C connectors: one native USB (target), one USB-UART bridge (host). PSRAM is not required. |
| USB-C video capture card (UVC-class)                | Tested with generic "Guermok USB3 Video" type devices. Anything UVC works.  |
| USB-C cable to target video out                     | HDMI-to-USB-C if the target has HDMI.                                       |
| Two USB-C data cables                               | One Mac↔ESP32 "COM"; one ESP32 "USB"↔target. Power-only cables won't work.  |
| macOS 15 (Sequoia) or 26 host                        | The app targets macOS 26.5 in the project but the APIs work on 15+.         |

## Building the macOS app

You need Xcode 26 or newer (the project targets macOS 26.5; lower the deployment target in the project settings if you need to build for older systems).

1. Open `CaptureKVM.xcodeproj` in Xcode.
2. In the **CaptureKVM** target → **Signing & Capabilities**: pick your team for code signing.
3. In **Build Settings**, confirm:
   - **Code Signing Entitlements** = `CaptureKVM/CaptureKVM.entitlements`
   - **Privacy - Camera Usage Description** (`INFOPLIST_KEY_NSCameraUsageDescription`) is set to a short string. Without this the system kills the app at the first capture-device access.
4. Cmd-B to build.

### Entitlements

The app is sandboxed. `CaptureKVM.entitlements` requests:

- `app-sandbox` plus `device.camera`, `device.usb`, `device.bluetooth`, `network.client`, `network.server`
- `files.user-selected.read-only`
- `temporary-exception.files.absolute-path.read-only` for `/dev/` (needed to `opendir()` for serial port enumeration)
- `temporary-exception.files.absolute-path.read-write` for `/dev/cu.` (needed to `open()` the bridge port)

Note that Apple is progressively restricting the `temporary-exception` entitlements on newer macOS releases. If the bridge port refuses to open even with these set, the pragmatic fallback is to disable **App Sandbox** in **Signing & Capabilities** entirely — hardened runtime stays on, camera access still works via the `NSCameraUsageDescription`, and serial open is unrestricted.

## Building and flashing the firmware

The sketch uses the **Arduino-ESP32** core (3.x) and its `USBHIDKeyboard` / `USBHIDMouse` high-level classes. You can build with Arduino IDE 2.x or directly with `arduino-cli`.

### One-time setup (Arduino IDE)

1. Install the Arduino IDE 2.x.
2. **Preferences → Additional Boards Manager URLs**: add
   `https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json`
3. **Tools → Board → Boards Manager**: install **esp32** by Espressif (3.x or newer).
4. **Tools → Board** → **ESP32 Arduino → ESP32S3 Dev Module**.

### Tools menu settings (important)

| Setting              | Value                                  |
| -------------------- | -------------------------------------- |
| USB CDC On Boot      | **Disabled**                           |
| USB Mode             | **USB-OTG (TinyUSB)**                  |
| Upload Mode          | **UART0 / Hardware CDC**               |
| CPU Frequency        | 240 MHz (WiFi)                         |
| Flash Mode           | QIO 80 MHz                             |
| Flash Size           | 8 MB (for N8R2)                        |
| Partition Scheme     | 8M with spiffs (3MB APP/1.5MB SPIFFS)  |
| PSRAM                | **Disabled**                           |
| Upload Speed         | 460800 (921600 sometimes glitches)     |

### Flashing from the IDE

1. Plug the dev kit's **COM** port into your Mac.
2. **Tools → Port** → pick the new `/dev/cu.usbmodemXXXX` device.
3. Open `ESP32KVMFirmware/ESP32KVMFirmware.ino`.
4. Click **Upload** (the right-arrow button).

### Flashing from the command line

`arduino-cli` is bundled with the IDE on macOS at `/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli`. Quit the CaptureKVM app first (the Mac app holding the port blocks the bootloader handshake), then:

```
ARDCLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=default,FlashSize=8M,PartitionScheme=default_8MB,PSRAM=disabled,UploadMode=default,UploadSpeed=460800"
PORT="/dev/cu.usbmodemXXXX"

"$ARDCLI" compile --fqbn "$FQBN" ESP32KVMFirmware
"$ARDCLI" upload  --fqbn "$FQBN" --port "$PORT" ESP32KVMFirmware
```

## Using the app

1. Plug the **COM** port of the ESP32 dev kit into the Mac.
2. Plug the **USB** port of the ESP32 dev kit into the target machine.
3. Plug the USB-C capture card into the Mac, and run an HDMI/DisplayPort cable from the target into the capture card.
4. Launch CaptureKVM.
5. In the toolbar:
   - **Video** dropdown — pick the capture card. On first use, macOS prompts for camera access; allow it. The preview should fill the window.
   - **ESP32** dropdown — pick the `/dev/cu.usbmodem...` matching the COM port. Click **Connect**. The status label switches to "ESP32 Connected".
   - **Capture Input** toggle — turns on event forwarding. The host cursor disappears; your mouse drives the target's cursor (shown in the captured video). The "Input captured — fn+Esc to release" status label appears.
6. Press **fn+Esc** to release capture (plain Esc passes through to the target).
7. **Paste to Target** button (or **Cmd+Shift+V** in capture mode) types the host clipboard into the target as synthesized keystrokes. ASCII only; Unicode beyond ASCII is silently skipped.

### Function keys on the host

macOS reserves F1–F12 for system functions by default (brightness, volume, etc.) and those events never reach our app. Either press **fn+F-key** to send the standard function key, or enable **System Settings → Keyboard → Keyboard Shortcuts → Function Keys → "Use F1, F2, etc. keys as standard function keys"** globally.

## Status indicators

### Toolbar (in-app)

- **Video OK / No Video** — capture session is running.
- **ESP32 Connected / Disconnected** — serial link to the bridge.
- **Input captured — fn+Esc to release** — appears only while capture is active.

### Onboard RGB LED on the ESP32

- **Slow dim-green pulse (1 Hz)** — the target machine has enumerated the HID device.
- **Fast dim-red blink (4 Hz)** — the target has not enumerated (bad cable, wrong port, target not powered).
- **Brief dim-blue flash (~50 ms)** — a valid frame was decoded from UART. Useful for confirming the Mac→ESP32 link end to end.

## Troubleshooting

| Symptom                                          | Likely cause                                                                  |
| ------------------------------------------------ | ----------------------------------------------------------------------------- |
| Capture card doesn't appear in the Video picker  | Camera entitlement / usage description missing, or sandbox blocking enumeration. |
| Picker shows the port but Connect surfaces `errno=1 (Operation not permitted)` | Sandbox is blocking `open("/dev/cu.*")`. Either fix the entitlements wiring or disable App Sandbox for this build. |
| `errno=2 (No such file)` after unplug             | Stale path — the 2-second poll will refresh; reconnect once the new path is selected. |
| Mac app keeps the port open and `esptool` fails  | Click **Disconnect** in the app, or quit it, before flashing.                  |
| Target enumerates but no keystrokes arrive       | Try a different USB-C cable on the **USB** port — many cables are power-only.  |
| Mouse cursor on target is "stuck"                | We send relative deltas. The host cursor is hidden + decoupled while capture is on — fn+Esc to recover. |
| Function keys do nothing on the target           | macOS swallows F-keys for system functions by default; use **fn+F-key** or change the setting. |
| Pasted text has missing characters               | Non-ASCII characters are skipped; speed is ~60 chars/sec; if a target buffer is full or focus changes, characters can drop. |

## Limitations / known gaps

- ASCII paste only. Unicode beyond ASCII (emoji, accented characters, non-US layouts) is silently skipped.
- US keyboard layout assumed for both the host event mapping and the paste character map.
- No screen-relative absolute pointer mode — we send relative HID deltas. That's why the host cursor must be captured (hidden + warped + decoupled).
- macOS' "Use F1, F2, etc. keys as standard function keys" is a system setting, not something the app can override per-window.
- Wake-from-sleep on the target depends on the target OS's USB-wake configuration (e.g., `/sys/bus/usb/devices/.../power/wakeup` on Linux). The KVM app can't enable wake on its own.
- Apple's `temporary-exception` entitlements for `/dev/` paths are being progressively restricted on newer macOS versions. If the sandboxed build can't open the serial port, fall back to disabling App Sandbox.

## License

No license currently specified. If you intend to use or redistribute this, add a license file appropriate to your needs.
