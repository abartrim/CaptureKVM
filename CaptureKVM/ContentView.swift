//
//  ContentView.swift
//  CaptureKVM
//
//  Created by Aaron Bartrim on 5/21/26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 8) {
            // Controls
            HStack(spacing: 12) {
                // Video device picker
                Picker("Video", selection: $model.selectedVideoUniqueID) {
                    Text("— Select —").tag("")
                    ForEach(model.videoDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .frame(minWidth: 220)
                .onChange(of: model.selectedVideoUniqueID) { _, newValue in
                    model.selectVideoDevice(uniqueID: newValue)
                }

                // Transport picker (USB Serial vs Bluetooth)
                Picker("Link", selection: $model.transportKind) {
                    ForEach(TransportKind.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .frame(width: 170)
                .disabled(model.isConnected)
                .onChange(of: model.transportKind) { _, newKind in
                    if newKind == .bluetooth { model.startBLEScan() }
                    else { model.stopBLEScan() }
                }

                // Device picker — swaps based on transport
                if model.transportKind == .usbSerial {
                    Picker("ESP32", selection: $model.selectedSerialPath) {
                        Text("— Select —").tag("")
                        ForEach(model.serialPorts, id: \.self) { port in
                            Text(port).tag(port)
                        }
                    }
                    .frame(minWidth: 240)
                } else {
                    Picker("ESP32", selection: $model.selectedBLEPeripheralID) {
                        Text(model.blePeripherals.isEmpty ? "— Scanning… —" : "— Select —")
                            .tag(UUID?.none)
                        ForEach(model.blePeripherals) { p in
                            Text(p.name).tag(UUID?.some(p.id))
                        }
                    }
                    .frame(minWidth: 240)
                }

                Button(model.isConnected ? "Disconnect" : "Connect") {
                    if model.isConnected {
                        model.disconnect()
                    } else {
                        model.connect()
                    }
                }
                .disabled(
                    (model.transportKind == .usbSerial && model.selectedSerialPath.isEmpty) ||
                    (model.transportKind == .bluetooth && model.selectedBLEPeripheralID == nil)
                )

                Toggle("Capture Input", isOn: $model.captureInput)
                    .toggleStyle(.switch)
                    .disabled(!model.isConnected)
                    .help("When enabled, keyboard and mouse events over the video are forwarded to the ESP32.")

                Toggle("⌘↔⌃", isOn: $model.swapCmdCtrl)
                    .toggleStyle(.button)
                    .help("Swap host Cmd and Ctrl when sending modifiers. Enable for Linux/Windows targets so ⌘C/⌘V behave as Ctrl+C/Ctrl+V.")

                Button(model.isPasting ? "Pasting…" : "Paste to Target") {
                    model.pasteFromClipboard()
                }
                .disabled(!model.isConnected || model.isPasting)
                .help("Types the host clipboard into the target as keystrokes (also: Cmd+Shift+V while in capture mode).")

                Spacer()

                // Status
                HStack(spacing: 12) {
                    if model.captureInput {
                        Label("Input captured — fn+Esc to release", systemImage: "keyboard.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    Label(model.captureStatusText, systemImage: model.captureStatusOK ? "camera.viewfinder" : "exclamationmark.triangle")
                        .foregroundStyle(model.captureStatusOK ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    Label(model.serialStatusText, systemImage: model.isConnected ? "cable.connector" : "bolt.horizontal.circle")
                        .foregroundStyle(model.isConnected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
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

                // Transparent input layer to receive NSEvents
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
                .allowsHitTesting(model.isConnected) // Hit-test when connected; the view decides whether to activate or forward
            }
            .frame(minHeight: 360)
            .onAppear {
                model.refreshDevices()
                model.refreshSerialPorts()
            }
        }
    }
}

#Preview {
    ContentView()
}
