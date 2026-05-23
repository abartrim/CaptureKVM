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

    // HUD that pops up briefly when capture toggles, like the system volume HUD.
    @State private var captureHudVisible: Bool = false
    @State private var captureHudWork: DispatchWorkItem? = nil

    // Fullscreen auto-hide toolbar state.
    @State private var isFullScreen: Bool = false
    @State private var toolbarVisible: Bool = true
    @State private var toolbarHideTimer: Timer? = nil

    var body: some View {
        Group {
            if isFullScreen {
                fullScreenLayout
            } else {
                windowedLayout
            }
        }
        .background(WindowAccessor(isFullScreen: $isFullScreen))
        .overlay(alignment: .center) {
            if captureHudVisible {
                captureHud
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.captureInput) { _, _ in flashCaptureHud() }
        .onChange(of: isFullScreen) { _, fs in
            // Show the toolbar at first when entering fullscreen, then auto-hide.
            toolbarVisible = true
            if fs { armToolbarAutoHide(after: 2.5) }
            else  { cancelToolbarAutoHide() }
        }
        .onAppear {
            model.refreshDevices()
            model.refreshSerialPorts()
        }
    }

    // MARK: - Layouts

    private var windowedLayout: some View {
        VStack(spacing: 8) {
            actionBar.padding(.horizontal)
            if !model.lastSerialError.isEmpty { errorBanner }
            previewArea
        }
    }

    private var fullScreenLayout: some View {
        ZStack(alignment: .top) {
            previewArea                         // video fills the whole screen
                .ignoresSafeArea()

            if toolbarVisible {
                VStack(spacing: 6) {
                    actionBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                    if !model.lastSerialError.isEmpty { errorBanner }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onHover { hovering in
                    if hovering { cancelToolbarAutoHide() }
                    else { armToolbarAutoHide(after: 1.5) }
                }
            } else {
                // Invisible hover strip at the very top reveals the toolbar.
                Color.clear
                    .frame(height: 6)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { revealToolbar() }
                    }
            }
        }
    }

    // MARK: - Sub-views

    private var actionBar: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: $model.connectionMode) {
                ForEach(ConnectionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 160)

            if model.connectionMode == .local {
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
            } else {
                TextField("Agent URL", text: $model.remoteBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, maxWidth: 280)

                SecureField("Auth token", text: $model.remoteAuthToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 240)
            }

            Button(model.isConnected ? "Disconnect" : "Connect") {
                if model.isConnected { model.disconnect() } else { model.connect() }
            }
            .fixedSize()
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(
                model.connectionMode == .local
                    ? ((model.transportKind == .usbSerial && model.selectedSerialPath.isEmpty) ||
                       (model.transportKind == .bluetooth && model.selectedBLEPeripheralID == nil))
                    : (model.remoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                       model.remoteAuthToken.isEmpty)
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
    }

    private var errorBanner: some View {
        Text(model.lastSerialError)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .padding(.horizontal)
    }

    private var previewArea: some View {
        ZStack {
            CapturePreviewView(displayLayer: model.capture.displayLayer)
                .background(Color.black)

            if model.connectionMode == .remote && !model.captureStatusOK {
                Color.black.opacity(0.55)
                VStack(spacing: 10) {
                    Image(systemName: "network")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(model.isConnected ? "Waiting for remote video…" : "Remote agent disconnected")
                        .font(.headline)
                    Text(model.isConnected
                         ? "The client has negotiated the session and is listening for encrypted H.264 video on the agent's UDP video port."
                         : "Connect to a remote agent to begin the remote preview stream.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                }
            }

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
    }

    // MARK: - Capture HUD (Apple bezel style)

    private var captureHud: some View {
        VStack(spacing: 8) {
            Image(systemName: model.captureInput ? "keyboard.fill" : "keyboard")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(.primary)
            Text(model.captureInput ? "Input Captured" : "Capture Released")
                .font(.headline)
            if model.captureInput {
                Text("Press **fn + Esc** to release")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 18)
        .frame(width: 280, height: 180)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    private func flashCaptureHud() {
        captureHudWork?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            captureHudVisible = true
        }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.28)) {
                self.captureHudVisible = false
            }
        }
        captureHudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // MARK: - Fullscreen toolbar auto-hide

    private func revealToolbar() {
        withAnimation(.easeOut(duration: 0.18)) { toolbarVisible = true }
        armToolbarAutoHide(after: 2.5)
    }

    private func armToolbarAutoHide(after seconds: TimeInterval) {
        cancelToolbarAutoHide()
        toolbarHideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            withAnimation(.easeIn(duration: 0.25)) { toolbarVisible = false }
        }
    }

    private func cancelToolbarAutoHide() {
        toolbarHideTimer?.invalidate()
        toolbarHideTimer = nil
    }

    // MARK: - Status strip (icon-only with tooltips)

    private var statusStrip: some View {
        HStack(spacing: 10) {
            StatusIcon(
                systemImage: model.captureStatusOK ? "video.fill" : "video.slash",
                active: model.captureStatusOK,
                color: model.captureStatusOK ? .green : .secondary,
                help: model.captureStatusText
            )

            StatusIcon(
                systemImage: linkIconName,
                active: model.isConnected,
                color: model.isConnected ? .green : .secondary,
                help: model.isConnected
                    ? "\(linkLabel) connected · \(model.serialStatusText)"
                    : "\(linkLabel) not connected"
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
        if model.connectionMode == .remote {
            return model.isConnected ? "network" : "network.slash"
        }
        switch model.transportKind {
        case .usbSerial: return model.isConnected ? "cable.connector" : "cable.connector.slash"
        case .bluetooth: return model.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var linkLabel: String {
        model.connectionMode == .remote ? "Remote over IP" : model.transportKind.rawValue
    }

    private var hidIconActive: Bool {
        if model.connectionMode == .remote { return model.isConnected }
        model.isConnected && model.transportKind == .usbSerial && model.hidMountedOnTarget
    }

    private var hidIconColor: Color {
        guard model.isConnected else { return .secondary }
        if model.connectionMode == .remote { return .green }
        if model.transportKind != .usbSerial { return .secondary }    // unknown on BLE
        return model.hidMountedOnTarget ? .green : .orange
    }

    private var hidIconHelp: String {
        guard model.isConnected else { return model.connectionMode == .remote ? "Remote agent not connected" : "ESP32 not connected" }
        if model.connectionMode == .remote {
            return "Remote HID reports are being sent to the Go agent over encrypted UDP"
        }
        if model.transportKind != .usbSerial {
            return "HID status only reported over USB Serial. Connect via USB to verify the target sees the HID device."
        }
        return model.hidMountedOnTarget
            ? "Target machine has enumerated the ESP32 as HID keyboard + mouse"
            : "Target machine has NOT enumerated the HID device. Check the ESP32's USB-C cable to the target."
    }
}

/// Bridges SwiftUI to the underlying NSWindow so we can react to the
/// system's enter/exit-fullscreen notifications. Mounted as a `.background`
/// so it doesn't participate in layout.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // The view isn't attached to a window yet at make-time; defer.
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            isFullScreen = window.styleMask.contains(.fullScreen)
            let nc = NotificationCenter.default
            nc.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                           object: window, queue: .main) { _ in isFullScreen = true }
            nc.addObserver(forName: NSWindow.didExitFullScreenNotification,
                           object: window, queue: .main) { _ in isFullScreen = false }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
