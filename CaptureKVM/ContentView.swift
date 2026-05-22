//
//  ContentView.swift
//  CaptureKVM
//
//  Created by Aaron Bartrim on 5/21/26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            // Single-row action bar. Configurable controls live in Settings (⌘,).
            HStack(spacing: 10) {
                Picker("Video", selection: $model.selectedVideoUniqueID) {
                    Text("— Select —").tag("")
                    ForEach(model.videoDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .frame(minWidth: 180, maxWidth: 240)
                .onChange(of: model.selectedVideoUniqueID) { _, newValue in
                    model.selectVideoDevice(uniqueID: newValue)
                }

                Picker("Link", selection: $model.transportKind) {
                    ForEach(TransportKind.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .frame(width: 150)
                .disabled(model.isConnected)
                .onChange(of: model.transportKind) { _, newKind in
                    if newKind == .bluetooth { model.startBLEScan() }
                    else { model.stopBLEScan() }
                }

                if model.transportKind == .usbSerial {
                    Picker("ESP32", selection: $model.selectedSerialPath) {
                        Text("— Select —").tag("")
                        ForEach(model.serialPorts, id: \.self) { port in
                            Text(port).tag(port)
                        }
                    }
                    .frame(minWidth: 200, maxWidth: 260)
                } else {
                    Picker("ESP32", selection: $model.selectedBLEPeripheralID) {
                        Text(model.blePeripherals.isEmpty ? "— Scanning… —" : "— Select —")
                            .tag(UUID?.none)
                        ForEach(model.blePeripherals) { p in
                            Text(p.name).tag(UUID?.some(p.id))
                        }
                    }
                    .frame(minWidth: 200, maxWidth: 260)
                }

                Button(model.isConnected ? "Disconnect" : "Connect") {
                    if model.isConnected { model.disconnect() } else { model.connect() }
                }
                .fixedSize()                      // keep the label visible no matter how tight the row gets
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(
                    (model.transportKind == .usbSerial && model.selectedSerialPath.isEmpty) ||
                    (model.transportKind == .bluetooth && model.selectedBLEPeripheralID == nil)
                )

                Toggle("Capture Input", isOn: $model.captureInput)
                    .toggleStyle(.switch)
                    .disabled(!model.isConnected)
                    .help("Forward host keyboard + mouse events to the target. Click the preview to enable; press fn+Esc to release.")

                Button(model.isPasting ? "Pasting…" : "Paste") {
                    model.pasteFromClipboard()
                }
                .fixedSize()
                .disabled(!model.isConnected || model.isPasting)
                .help("Types the host clipboard into the target as keystrokes (also: ⇧⌘V while in capture mode).")

                Spacer()

                statusStrip
            }
            .padding(.horizontal)

            if !model.lastSerialError.isEmpty {
                Text(model.lastSerialError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal)
            }

            ZStack {
                CapturePreviewView(displayLayer: model.capture.displayLayer)
                    .background(Color.black)

                InputForwarderView(
                    isActive: model.captureInput,
                    onKeyDown: { event in model.handleKeyDown(event) },
                    onKeyUp:   { event in model.handleKeyUp(event) },
                    onFlagsChanged: { event in model.handleFlagsChanged(event) },
                    onMouseMove: { dx, dy in model.handleMouseMove(dx: dx, dy: dy) },
                    onMouseButton: { down, button in model.handleMouseButton(down: down, button: button) },
                    onScroll: { dx, dy in model.handleScroll(dx: dx, dy: dy) },
                    onEscapeRelease: { model.captureInput = false },
                    onPasteFromHost: { model.pasteFromClipboard() },
                    onActivateCapture: {
                        guard model.isConnected else { return }
                        model.captureInput = true
                    }
                )
                .allowsHitTesting(model.isConnected)
            }
            .frame(minHeight: 360)
            .onAppear {
                model.refreshDevices()
                model.refreshSerialPorts()
            }
        }
    }

    // MARK: - Status strip (icon-only with tooltips)

    private var statusStrip: some View {
        HStack(spacing: 10) {
            StatusIcon(
                systemImage: model.captureStatusOK ? "video.fill" : "video.slash",
                active: model.captureStatusOK,
                color: model.captureStatusOK ? .green : .secondary,
                help: model.captureStatusOK ? "Video signal OK" : "No video signal"
            )

            StatusIcon(
                systemImage: linkIconName,
                active: model.isConnected,
                color: model.isConnected ? .green : .secondary,
                help: model.isConnected
                    ? "\(model.transportKind.rawValue) connected · \(model.serialStatusText)"
                    : "\(model.transportKind.rawValue) not connected"
            )

            // HID enumeration on the target. We only know this when the firmware tells us
            // (USB Serial transport polls every 2s). Over BLE we show it as "unknown".
            StatusIcon(
                systemImage: "bolt.horizontal.fill",
                active: hidIconActive,
                color: hidIconColor,
                help: hidIconHelp
            )

            StatusIcon(
                systemImage: "keyboard.fill",
                active: model.captureInput,
                color: model.captureInput ? .accentColor : .secondary,
                help: model.captureInput ? "Input captured — fn+Esc to release" : "Input not captured (click preview to capture)"
            )
        }
        .padding(.horizontal, 4)
    }

    private var linkIconName: String {
        switch model.transportKind {
        case .usbSerial: return model.isConnected ? "cable.connector" : "cable.connector.slash"
        case .bluetooth: return model.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var hidIconActive: Bool {
        model.isConnected && model.transportKind == .usbSerial && model.hidMountedOnTarget
    }

    private var hidIconColor: Color {
        guard model.isConnected else { return .secondary }
        if model.transportKind != .usbSerial { return .secondary }    // unknown on BLE
        return model.hidMountedOnTarget ? .green : .orange
    }

    private var hidIconHelp: String {
        guard model.isConnected else { return "ESP32 not connected" }
        if model.transportKind != .usbSerial {
            return "HID status only reported over USB Serial. Connect via USB to verify the target sees the HID device."
        }
        return model.hidMountedOnTarget
            ? "Target machine has enumerated the ESP32 as HID keyboard + mouse"
            : "Target machine has NOT enumerated the HID device. Check the ESP32's USB-C cable to the target."
    }
}

/// Small icon-only status indicator with a hover tooltip and an "active" dim/highlight.
private struct StatusIcon: View {
    let systemImage: String
    let active: Bool
    let color: Color
    let help: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .opacity(active ? 1.0 : 0.55)
            .frame(width: 22, height: 22)
            .help(help)
    }
}

#Preview {
    ContentView(model: AppModel())
}
