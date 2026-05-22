# Third-Party Notices

CaptureKVM is licensed under [GPL v3](LICENSE). It bundles and links the
following third-party software, which is acknowledged here as required by the
respective licenses. The original copyrights remain with their authors; the
combined work is distributed under the terms of GPL v3 (which is compatible
with each of these licenses).

## Bundled inside the macOS app

### esptool — Espressif Systems
- Used as a standalone binary for in-app ESP32 firmware flashing.
- Location in the app: `CaptureKVM.app/Contents/Resources/esptool`
- Upstream: <https://github.com/espressif/esptool>
- License: **GNU General Public License v2.0 or later**
- Copyright © Espressif Systems (Shanghai) Co., Ltd. and esptool contributors.

## Linked into the bundled ESP32 firmware

The firmware images shipped in `CaptureKVM.app/Contents/Resources/firmware-*.bin`
contain statically-linked code from the following projects:

### Arduino-ESP32 — Espressif Systems
- Provides the Arduino runtime, USB stack (TinyUSB integration), and HAL for
  the ESP32-S3.
- Upstream: <https://github.com/espressif/arduino-esp32>
- License: **Apache License 2.0** (with some LGPL 2.1 components)
- Copyright © Espressif Systems (Shanghai) Co., Ltd. and arduino-esp32
  contributors.

### NimBLE-Arduino — h2zero
- Provides the BLE host stack used by the firmware's GATT server.
- Upstream: <https://github.com/h2zero/NimBLE-Arduino>
- License: **Apache License 2.0**
- Copyright © Ryan Powell ("h2zero") and NimBLE-Arduino contributors.

### TinyUSB — Ha Thach and contributors
- Used by Arduino-ESP32 for the USB-OTG HID Keyboard + Mouse device classes.
- Upstream: <https://github.com/hathach/tinyusb>
- License: **MIT License**
- Copyright © 2018, hathach (tinyusb.org).

## Third-party hardware design (optional, not embedded in any executable)

### ESP32-S3-DevKitC "pins and no pins" case
- A `.3mf` file for a 3D-printable case ships in `ESP32KVMFirmware/`.
- Original design: <https://makerworld.com/en/models/551019-esp32-s3-devkitc-pins-and-no-pins-case>
- License: as specified by the designer on the MakerWorld page. Visit the link
  for the canonical version and the original creator's attribution + license
  terms. The bundled `.3mf` is a convenience copy; if you remix or redistribute
  it, do so according to the original license.

---

Full license texts for each project are available at the upstream URLs listed
above. This NOTICE file lists the third-party software that ships *embedded* in
CaptureKVM artifacts. The macOS app itself uses only Apple system frameworks
(SwiftUI, AppKit, AVFoundation, CoreBluetooth, etc.) and our own GPL v3 code.
