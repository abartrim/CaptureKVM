import SwiftUI

/// User-facing help. Opened from Help → CaptureKVM Help (or ⌘?).
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                section("What this app does") {
                    Text("CaptureKVM turns a USB-C capture card and an ESP32-S3 into a do-it-yourself KVM. The capture card shows you the target machine's screen; the ESP32 emits keyboard + mouse events to the target over USB HID. The Mac controls the ESP32 via USB serial or Bluetooth Low Energy.")
                }

                section("Getting started") {
                    bullet("**Get the board:** ESP32-S3-DevKitC \"Dual Type-C\" — any flash size from 4 MB to 16 MB. Available on AliExpress / Amazon for ~$10–15. Look for two USB-C connectors, one labelled USB and the other labelled COM or UART.")
                    bullet("**Flash the firmware:** plug the board's COM port into your Mac, open **Settings (⌘,) → Firmware**, pick the port, click **Flash bundled firmware**. ~10 seconds.")
                    bullet("**Wire it up:** ESP32 \"USB\" port → target machine; target's HDMI → USB-C capture card → your Mac.")
                    bullet("**Connect:** main window — pick Video device, pick ESP32 serial port, click **Connect**, click the preview to capture input.")
                }

                section("Hardware wiring") {
                    bullet("USB-C capture card → into the Mac. Pick it in the Video dropdown.")
                    bullet("ESP32 **\"COM\" port** (UART-bridge USB-C) → into the Mac. Used for fast wired control + management.")
                    bullet("ESP32 **\"USB\" port** (native USB-OTG USB-C) → into the target machine. The target sees a USB keyboard + mouse.")
                    bullet("Target's video output (HDMI/DisplayPort) → into the capture card.")
                }

                section("The main window") {
                    Text("One action row with the only controls you change per session:")
                    bullet("**Video** — pick which capture device to preview.")
                    bullet("**Link** — choose between USB Serial and Bluetooth. Disabled while connected.")
                    bullet("**ESP32** — pick the matching serial port (USB) or BLE peripheral (Bluetooth).")
                    bullet("**Connect / Disconnect** — opens or closes the link to the ESP32.")
                    bullet("**Capture Input** — toggles forwarding of host keyboard/mouse to the target. You can also just click the preview to enter capture mode; press **fn+Esc** to release.")
                    bullet("**Paste** — types the host clipboard into the target as keystrokes (also: ⇧⌘V while in capture mode).")
                    Text("Everything else lives in **Settings (⌘,)**.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                section("Status icons (right side of the action row)") {
                    bullet("📹 **Video** — green when capture frames are flowing, dim when there's no signal.")
                    bullet("🔌 **Link** — cable icon over USB, antenna icon over BLE. Green when connected.")
                    bullet("⚡ **HID** — green when the **target machine** has enumerated the ESP32 as a USB keyboard + mouse, orange when it hasn't. Only reported over USB Serial (the firmware tells us). Over BLE we can't see this, so the icon stays neutral.")
                    bullet("⌨️ **Capture** — highlighted when input is being forwarded to the target.")
                    Text("Hover any icon for a one-line explanation of its current state.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                section("Settings window (⌘,)") {
                    Text("Things you set once and forget about:")
                    bullet("**Keyboard tab — Swap ⌘ ↔ ⌃** — host Cmd is sent as target Ctrl, host Ctrl as Super. Recommended for Linux / Windows targets.")
                    bullet("**Bluetooth tab — BLE PIN** — the current 6-digit pairing code (persisted on the ESP32).")
                    bullet("**Bluetooth tab — Rotate PIN** — generates a new random PIN and clears any existing bonds. Bonded Macs will need to pair again.")
                    bullet("**Bluetooth tab — BLE radio enabled** — turn the wireless radio off entirely (hardware-only mode). Persisted on the ESP32.")
                    Text("PIN management and BLE on/off are intentionally only changeable over the wired serial link — physical access required.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                section("Bluetooth pairing flow (one-shot)") {
                    bullet("Connect via **USB Serial** once. The Bluetooth tab in Settings will then show the **PIN** with a green \"Live\" badge.")
                    bullet("Click **Switch to Bluetooth & start pairing** in Settings → Bluetooth. The app disconnects USB, switches Link to Bluetooth, scans, and auto-selects the first KVM bridge it sees.")
                    bullet("Click **Connect** in the main toolbar. macOS pops a system pairing dialog asking for the 6-digit code; type the PIN that's shown in Settings.")
                    bullet("Done — the bond is persisted in macOS' keychain. Future BLE connects don't re-prompt.")
                }

                section("PIN status badge") {
                    bullet("**Live (green)** — the PIN was just read from the firmware via USB.")
                    bullet("**Cached (orange)** — the value is the last one this Mac saw. Connect via USB to refresh.")
                    bullet("**Unknown** — no PIN has ever been retrieved on this Mac. Connect via USB to get one.")
                }

                section("Hardware-only mode") {
                    Text("Turn off **BLE radio enabled** in Settings → Bluetooth. The ESP32's BLE controller shuts down completely; only the wired USB-serial link can control the bridge. The setting persists across reboots. Turn back on the same way.")
                }

                section("Function keys") {
                    Text("macOS reserves F1–F12 for system functions by default. Either press **fn + F-key** so the function key actually reaches our app, or enable **System Settings → Keyboard → Keyboard Shortcuts → Function Keys → \"Use F1, F2, etc. keys as standard function keys\"**.")
                }

                section("ESP32 onboard LED meanings") {
                    Text("The LED is activity-driven — it stays off while the bridge is idle, so it isn't blinking at you in a dark room. It only lights up when something interesting is happening:")
                        .font(.callout)
                    bullet("**Brief dim blue flash** — a valid control frame was just decoded (UART or BLE). Flickers as you type / move the mouse.")
                    bullet("**Slow dim red blink** — the target hasn't enumerated the USB HID device. Check the cable from the ESP32's \"USB\" port to the target.")
                    bullet("**Off** — idle. Bridge is fine; the host just isn't sending anything.")
                    bullet("Mode info (BLE on/off, client connected, etc.) is shown in the app rather than on the LED.")
                }

                section("Flashing firmware from the app") {
                    Text("The Mac app ships the matching ESP32 firmware inside its own bundle. To flash:")
                        .font(.callout)
                    bullet("Open **Settings → Firmware**.")
                    bullet("Pick the ESP32's COM (USB-UART bridge) port from the dropdown.")
                    bullet("Click **Flash bundled firmware**. The app closes any existing serial connection, runs the bundled `esptool` against the port, and reports progress. Takes about 10 seconds.")
                    bullet("When it's done the ESP32 hard-resets and the new firmware is live.")
                }

                section("Want to build or modify the firmware?") {
                    Text("See `BUILDING.md` in the project repository for the full build flow — Arduino IDE setup, FQBN settings, the `arduino-cli` one-liner, and how to refresh the firmware artifacts the app bundles for in-app flashing.")
                }

                section("Troubleshooting") {
                    bullet("**\"No response from ESP32 at any baud.\"** Re-flash from `ESP32KVMFirmware/`. Disconnect the app first; it holds the port.")
                    bullet("**HID icon stays orange even when connected.** Target machine isn't seeing the HID. Reseat the USB-C cable to the target's \"USB\" port, or try a known-good data cable. The icon updates within 2s.")
                    bullet("**BLE pairing prompt never appears.** Quit + relaunch the app. Verify the signed entitlements include `com.apple.security.device.bluetooth`. If still nothing: `tccutil reset Bluetooth Trustonica.CaptureKVM`, then `sudo pkill bluetoothd`, then relaunch.")
                    bullet("**Lost track of the PIN.** Connect via USB Serial → Settings (⌘,) → Bluetooth tab.")
                    bullet("**Function keys / system shortcuts get intercepted by macOS.** Cmd+Space, fn+F11 etc. hit the host first — a macOS limitation outside our event tap.")
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2).bold()
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(.init(text))   // markdown-enabled init
        }
    }
}

#Preview {
    HelpView().frame(width: 720, height: 800)
}
