# Building CaptureKVM from source

This document covers everything you need to build the Mac app from source, modify and re-flash the firmware, and understand how the pieces fit together. For end-user instructions (download a release, plug in, flash, use), see [README.md](README.md).

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
                              |  Reads UART0 + BLE GATT;    |   | runs    |
                              |  decodes COBS+CRC8 frames;  |   | Capture |
                              |  emits HID reports.         |   | KVM.app |
                              |                             |   |         |
                              | ESP32-S3 "COM" port         |<--+         |
                              | (UART bridge chip)          |   |         |
                              +-----------------------------+   +---------+
                                                                     ^
                                       host keyboard + mouse ---------+
```

Two USB cables run between the Mac and the ESP32-S3 dev kit:

- The **"COM"** USB-C is the bridge chip (CP2102N or CH343) that exposes UART0 as a virtual serial port on the Mac. The Mac app sends framed control packets over it. This is also the channel used for in-app firmware flashing.
- The **"USB"** USB-C is the ESP32-S3's native USB OTG. It's plugged into the **target machine**, where it enumerates as a USB HID keyboard + mouse.

A third USB connection — the video capture card — runs from the target's video output to the host Mac.

The Mac app can also talk to the bridge over **Bluetooth LE** (NimBLE GATT server on the ESP32 side). Both transports run concurrently in the firmware.

## Wire protocol (host → ESP32)

Each frame is:

```
[type byte][payload bytes...][CRC8 trailer]   <- raw frame
COBS-encode the whole thing, append 0x00.     <- on the wire
```

- CRC8 polynomial `0x07`.
- COBS keeps the byte stream `0x00`-free so the trailing `0x00` is an unambiguous delimiter.

Frame types:

| Type | Direction | Meaning | Payload |
| ---- | --------- | ------- | ------- |
| `0x01` | host → device | Boot keyboard report | `[modifiers, reserved=0, k1..k6]` (8 bytes) |
| `0x02` | host → device | Boot mouse report | `[buttons, dx, dy, wheel_vert]` (4 bytes; int8s) |
| `0x80` | host → device | Ping (baud probe) | empty; device replies with a single `0xAA` byte (UART) or notify (BLE) |
| `0x81` | host → device | GET_PIN (UART only) | empty; device sends back the 6-digit BLE PIN as ASCII |
| `0x82` | host → device | ROTATE_PIN (UART only) | empty; device generates a new PIN, clears bonds, returns the new value |
| `0x83` | host → device | BLE_ENABLE (UART only) | empty; device turns on its BLE radio + advertising, persists the setting |
| `0x84` | host → device | BLE_DISABLE (UART only) | empty; device shuts down BLE for hardware-only mode |
| `0x85` | host → device | GET_STATE (UART only) | empty; device returns `[ble_enabled, hid_mounted, ble_client, pin(6 ASCII), name…]` |

The encoder/decoder lives in `CaptureKVM/HIDEncoder.swift` (Mac) and `ESP32KVMFirmware/ESP32KVMFirmware.ino` (firmware).

## Repository layout

```
CaptureKVM.xcodeproj/        Xcode project for the macOS app.
CaptureKVM/                  macOS app sources.
  AppModel.swift               Top-level model: device enumeration, hot-plug,
                               input handling, paste-from-host, frame dispatch,
                               BLE state, PIN management.
  CaptureManager.swift         AVCaptureSession + sample-buffer display layer
                               for the USB-C capture card preview.
  ESP32Serial.swift            POSIX serial open + baud negotiation + framed-
                               response read loop.
  BluetoothTransport.swift     CoreBluetooth central wrapper: scan, connect,
                               write, subscribe to notify.
  FrameTransport.swift         Shared protocol for UART and BLE transports.
  FirmwareFlasher.swift        @MainActor wrapper around the bundled esptool
                               for in-app firmware flashing.
  HIDEncoder.swift             COBS + CRC8 framing; US keyCode -> HID usage map;
                               US character -> HID usage map for paste.
  InputForwarderView.swift     Transparent NSView that intercepts keyboard +
                               mouse events; cursor hide + warp + decoupling.
  ContentView.swift            Main SwiftUI window: toolbar + preview + status.
  SettingsView.swift           ⌘, window: Keyboard / Bluetooth / Firmware tabs.
  HelpView.swift               ⌘? help window content.
  CaptureKVMApp.swift          App scenes + commands.
  CaptureKVM.entitlements      Code-signing entitlements.
  Assets.xcassets              App icon + accent colour.
  Resources/                   esptool binary + firmware .bin files bundled
                               into the app for in-app flashing.

ESP32KVMFirmware/            Arduino sketch for the ESP32-S3.
  ESP32KVMFirmware.ino
  esp32_s3_snap_sleeve_case.scad   OpenSCAD source for a printable case.

ESP32KVMFirmware_BLEOnly/    Minimal BLE-only diagnostic sketch — useful for
                             debugging discoverability in isolation.
```

## Building the macOS app

You need Xcode 26 or newer (the project targets macOS 26.5; lower the deployment target in the project settings if you need to build for older systems).

1. Open `CaptureKVM.xcodeproj` in Xcode.
2. In the **CaptureKVM** target → **Signing & Capabilities**: pick your team for code signing.
3. In **Build Settings**, confirm:
   - **Code Signing Entitlements** = `CaptureKVM/CaptureKVM.entitlements`
   - **Privacy - Camera Usage Description** (`INFOPLIST_KEY_NSCameraUsageDescription`) is set to a short string. Without this the system kills the app at the first capture-device access.
4. ⌘B to build.

### Entitlements

The current entitlements file requests:

- `com.apple.security.device.camera` — required for capture card access via AVFoundation.
- `com.apple.security.device.usb` — USB device class access (mostly informational; serial access works without sandbox).
- `com.apple.security.device.bluetooth` — required for CoreBluetooth scan/connect.
- `com.apple.security.network.client` / `network.server` — kept for future expansion.
- `com.apple.security.cs.disable-library-validation` and `com.apple.security.cs.allow-unsigned-executable-memory` — required because we ship a PyInstaller-built `esptool` inside the bundle for in-app firmware flashing. Without these, hardened runtime refuses to load esptool's bundled Python libraries.

App Sandbox is currently **disabled** because Apple is progressively restricting the `temporary-exception` entitlements for `/dev/cu.*` access that sandboxed serial code would need. Hardened Runtime stays on.

## Building and flashing the firmware

The sketch uses the **Arduino-ESP32** core (3.x) and **h2zero's NimBLE-Arduino** library (the built-in BLE stack in 3.3.7+ has a known regression that breaks discoverability on macOS / iOS).

### One-time setup (Arduino IDE)

1. Install the Arduino IDE 2.x.
2. **Preferences → Additional Boards Manager URLs**: add
   `https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json`
3. **Tools → Board → Boards Manager**: install **esp32** by Espressif (3.x or newer).
4. **Tools → Manage Libraries**: install **NimBLE-Arduino** by h2zero (2.5.0 or newer).
5. **Tools → Board** → **ESP32 Arduino → ESP32S3 Dev Module**.

### Tools menu settings (important)

| Setting              | Value                                  |
| -------------------- | -------------------------------------- |
| USB CDC On Boot      | **Disabled**                           |
| USB Mode             | **USB-OTG (TinyUSB)**                  |
| Upload Mode          | **UART0 / Hardware CDC**               |
| CPU Frequency        | 240 MHz (WiFi)                         |
| Flash Mode           | QIO 80 MHz                             |
| Flash Size           | 8 MB                                   |
| Partition Scheme     | 8M with spiffs (3MB APP/1.5MB SPIFFS)  |
| PSRAM                | **Disabled** (gives a universal binary across all S3 module variants) |
| Upload Speed         | 460800 (921600 sometimes glitches)     |

### Flashing from the IDE

1. Plug the dev kit's **COM** port into your Mac.
2. **Tools → Port** → pick the new `/dev/cu.usbmodemXXXX` device.
3. Open `ESP32KVMFirmware/ESP32KVMFirmware.ino`.
4. Click **Upload** (the right-arrow button).

### Flashing from the command line

`arduino-cli` is bundled with the IDE on macOS at `/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli`. Quit the CaptureKVM app first (the Mac app holding the port blocks the bootloader handshake), then:

```sh
ARDCLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=default,FlashSize=8M,PartitionScheme=default_8MB,PSRAM=disabled,UploadMode=default,UploadSpeed=460800"
PORT="/dev/cu.usbmodemXXXX"

"$ARDCLI" compile --fqbn "$FQBN" ESP32KVMFirmware
"$ARDCLI" upload  --fqbn "$FQBN" --port "$PORT" ESP32KVMFirmware
```

### Rebuilding the firmware bundled with the Mac app

When you change the firmware and want the next `CaptureKVM.app` release to ship the new version:

```sh
"$ARDCLI" compile --fqbn "$FQBN" --output-dir /tmp/kvm_fw_build ESP32KVMFirmware

cp /tmp/kvm_fw_build/ESP32KVMFirmware.ino.bin            CaptureKVM/Resources/firmware-app.bin
cp /tmp/kvm_fw_build/ESP32KVMFirmware.ino.bootloader.bin CaptureKVM/Resources/firmware-bootloader.bin
cp /tmp/kvm_fw_build/ESP32KVMFirmware.ino.partitions.bin CaptureKVM/Resources/firmware-partitions.bin
```

Then rebuild the Mac app — the new bins are bundled into `CaptureKVM.app/Contents/Resources/` automatically.

## Memory footprint

Firmware (PSRAM-disabled universal build):

| Memory | Used | Total | Headroom |
| --- | --- | --- | --- |
| Flash (app partition) | ~650 KB | 3 MB | ~2.4 MB free |
| DRAM globals | ~62 KB | 320 KB | ~258 KB |
| DRAM available for stack + heap | — | — | ~265 KB |

NimBLE + TinyUSB account for the bulk of both numbers; our own code is a few KB.

## BLE security model

- BLE writes require **LE Secure Connections** pairing with a 6-digit numeric PIN.
- The PIN is randomly generated on first boot and stored in NVS (`Preferences` namespace `"kvm"`, key `"passkey"`).
- "Display Only" IO capability → macOS prompts the user to enter the code. The PIN never leaves the firmware over BLE; it's only readable via UART.
- Pairing the encryption requirement on the **notify** characteristic (`READ_AUTHEN`) is what actually triggers CoreBluetooth's pairing dialog — `writeWithoutResponse` calls don't surface auth errors back to the OS.
- Bonds are stored in NVS by NimBLE. Rotating the PIN deletes all bonds and forces re-pairing.
- The radio can be turned off entirely (hardware-only mode) over UART; setting persists.

## Known limitations

- **ASCII paste only.** Non-ASCII characters (emoji, accented characters, non-US layouts) are silently skipped by the synthesized-keystroke paste path.
- **US keyboard layout assumed** for both the host event mapping and the paste character map.
- **No screen-relative absolute pointer mode** — we send relative HID deltas. That's why the host cursor must be captured (hidden + warped + decoupled).
- macOS' "Use F1, F2, etc. as standard function keys" is a system setting; the app can't override it per-window.
- **Wake-from-sleep on the target** depends on the target OS's USB-wake configuration (e.g., `/sys/bus/usb/devices/.../power/wakeup` on Linux). The app can't enable wake on its own.
