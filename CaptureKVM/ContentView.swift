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

                // Serial port picker
                Picker("ESP32", selection: $model.selectedSerialPath) {
                    Text("— Select —").tag("")
                    ForEach(model.serialPorts, id: \.self) { port in
                        Text(port).tag(port)
                    }
                }
                .frame(minWidth: 240)

                Button(model.isConnected ? "Disconnect" : "Connect") {
                    if model.isConnected {
                        model.disconnect()
                    } else {
                        model.connect()
                    }
                }
                .disabled(model.selectedSerialPath.isEmpty)

                Toggle("Capture Input", isOn: $model.captureInput)
                    .toggleStyle(.switch)
                    .help("When enabled, keyboard and mouse events over the video are forwarded to the ESP32.")

                Spacer()

                // Status
                HStack(spacing: 12) {
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
                CapturePreviewView(session: model.capture.session)
                    .background(Color.black)
                    .overlay(alignment: .topLeading) {
                        if model.captureInput {
                            Text("Input captured — press fn+Esc to release")
                                .padding(6)
                                .background(.thinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding()
                        }
                    }

                // Transparent input layer to receive NSEvents
                InputForwarderView(
                    isActive: model.captureInput,
                    onKeyDown: { event in model.handleKeyDown(event) },
                    onKeyUp:   { event in model.handleKeyUp(event) },
                    onFlagsChanged: { event in model.handleFlagsChanged(event) },
                    onMouseMove: { dx, dy in model.handleMouseMove(dx: dx, dy: dy) },
                    onMouseButton: { down, button in model.handleMouseButton(down: down, button: button) },
                    onScroll: { dx, dy in model.handleScroll(dx: dx, dy: dy) },
                    onEscapeRelease: { model.captureInput = false }
                )
                .allowsHitTesting(model.captureInput) // Only intercept when active
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
