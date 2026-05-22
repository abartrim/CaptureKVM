import SwiftUI
import AppKit
import AVFoundation
import Combine

final class AppModel: ObservableObject {
    // Video
    @Published var videoDevices: [CaptureDeviceInfo] = []
    @Published var selectedVideoUniqueID: String = ""

    // Serial
    @Published var serialPorts: [String] = []
    @Published var selectedSerialPath: String = ""
    @Published var isConnected: Bool = false
    @Published var lastSerialError: String = ""

    // Paste-from-host state
    @Published var isPasting: Bool = false

    // Input capture toggle
    @Published var captureInput: Bool = false

    // Managers
    let capture = CaptureManager()
    let serial = ESP32Serial()

    // Keyboard state (6KRO)
    private var pressedUsages: Set<UInt8> = []
    private var modifiers: UInt8 = 0

    // Mouse state
    private var currentButtons: UInt8 = 0
    private var pendingDX: Int = 0
    private var pendingDY: Int = 0
    private var pendingWheelX: Int = 0
    private var pendingWheelY: Int = 0
    private var mouseTimer: DispatchSourceTimer?

    // Device hot-plug watchers
    private var serialPollTimer: DispatchSourceTimer?
    private var deviceConnectObserver: NSObjectProtocol?
    private var deviceDisconnectObserver: NSObjectProtocol?

    init() {
        setupMouseTimer()
        setupVideoDeviceWatcher()
        setupSerialPollTimer()
        serial.onConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                self?.isConnected = connected
                if !connected { self?.captureInput = false }
            }
        }
        serial.onError = { [weak self] message in
            DispatchQueue.main.async { self?.lastSerialError = message }
        }
    }

    deinit {
        if let o = deviceConnectObserver { NotificationCenter.default.removeObserver(o) }
        if let o = deviceDisconnectObserver { NotificationCenter.default.removeObserver(o) }
        serialPollTimer?.cancel()
        mouseTimer?.cancel()
    }

    // MARK: - UI helpers
    var captureStatusOK: Bool { capture.isRunning }
    var captureStatusText: String { capture.isRunning ? "Video OK" : "No Video" }
    var serialStatusText: String { isConnected ? "ESP32 Connected" : "ESP32 Disconnected" }

    // MARK: - Video
    func refreshDevices() {
        videoDevices = capture.enumerateVideoDevices()
        if !selectedVideoUniqueID.isEmpty, !videoDevices.contains(where: { $0.uniqueID == selectedVideoUniqueID }) {
            selectedVideoUniqueID = ""
        }
        if selectedVideoUniqueID.isEmpty, let first = videoDevices.first {
            selectedVideoUniqueID = first.uniqueID
            selectVideoDevice(uniqueID: selectedVideoUniqueID)
        }
    }

    func selectVideoDevice(uniqueID: String) {
        let id = uniqueID
        if let device = videoDevices.first(where: { $0.uniqueID == id }) {
            capture.start(device: device)
        }
    }

    // MARK: - Serial
    func refreshSerialPorts() {
        let newPorts = ESP32Serial.availablePorts()
        guard newPorts != serialPorts else { return }
        serialPorts = newPorts
        if selectedSerialPath.isEmpty, let first = newPorts.first { selectedSerialPath = first }
        if !selectedSerialPath.isEmpty, !newPorts.contains(selectedSerialPath) {
            if isConnected { disconnect() }
            selectedSerialPath = newPorts.first ?? ""
        }
    }

    // MARK: - Device hot-plug
    private func setupVideoDeviceWatcher() {
        let center = NotificationCenter.default
        deviceConnectObserver = center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
        }
        deviceDisconnectObserver = center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    private func setupSerialPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.refreshSerialPorts()
        }
        timer.resume()
        serialPollTimer = timer
    }

    func connect() {
        guard !selectedSerialPath.isEmpty else { return }
        serial.connect(path: selectedSerialPath)
    }

    func disconnect() {
        serial.disconnect()
    }

    // MARK: - Input handling
    func handleKeyDown(_ event: NSEvent) {
        guard captureInput else { return }
        let (usage, modBit) = KeycodeMap.usUsage(for: event)
        if let u = usage { pressedUsages.insert(u) }
        if let m = modBit { modifiers |= m }
        sendKeyboard()
    }

    func handleKeyUp(_ event: NSEvent) {
        guard captureInput else { return }
        let (usage, modBit) = KeycodeMap.usUsage(for: event)
        if let u = usage { pressedUsages.remove(u) }
        if let m = modBit { modifiers &= ~m }
        sendKeyboard()
    }

    func handleFlagsChanged(_ event: NSEvent) {
        guard captureInput else { return }
        let flags = event.modifierFlags
        var mod: UInt8 = 0
        if flags.contains(.shift)   { mod |= 0x02 }
        if flags.contains(.control) { mod |= 0x01 }
        if flags.contains(.option)  { mod |= 0x04 }
        if flags.contains(.command) { mod |= 0x08 }
        modifiers = mod
        sendKeyboard()
    }

    func handleMouseMove(dx: CGFloat, dy: CGFloat) {
        guard captureInput else { return }
        pendingDX += Int(dx.rounded())
        pendingDY += Int(dy.rounded())
    }

    func handleMouseButton(down: Bool, button: Int) {
        guard captureInput else { return }
        let bit: UInt8
        switch button {
        case 1: bit = 0x01
        case 2: bit = 0x02
        case 3: bit = 0x04
        default: return
        }
        if down { currentButtons |= bit } else { currentButtons &= ~bit }
        // Emit immediately so the press/release isn't held until the next movement frame.
        let payload: [UInt8] = [currentButtons, 0, 0, 0]
        sendMouse(payload: payload)
    }

    func handleScroll(dx: CGFloat, dy: CGFloat) {
        guard captureInput else { return }
        pendingWheelX += Int(dx.rounded())
        pendingWheelY += Int(dy.rounded())
    }

    private func sendKeyboard() {
        // Build 8-byte boot keyboard report
        var report = [UInt8](repeating: 0, count: 8)
        report[0] = modifiers
        report[1] = 0 // reserved
        let keys = Array(pressedUsages.prefix(6))
        for (i, k) in keys.enumerated() { report[2 + i] = k }
        let frame = HIDEncoder.frame(type: 0x01, payload: report)
        serial.send(frame: frame)
    }

    // MARK: - Paste from host

    func pasteFromClipboard() {
        guard !isPasting, isConnected else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        isPasting = true
        Task { [weak self] in
            await self?.sendAsKeystrokes(text)
            self?.isPasting = false
        }
    }

    private func sendAsKeystrokes(_ text: String) async {
        for ch in text {
            if ch == "\r" { continue } // collapse \r\n to a single Return
            guard let (usage, shift) = USCharacterMap.usage(for: ch) else { continue }
            sendOneShotKey(modifier: shift ? 0x02 : 0, key: usage)
            try? await Task.sleep(nanoseconds: 8_000_000)
            sendOneShotKey(modifier: 0, key: 0)
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// Sends a single keyboard frame WITHOUT touching pressedUsages/modifiers
    /// (so it can't conflict with the user's live keystroke state).
    private func sendOneShotKey(modifier: UInt8, key: UInt8) {
        var report = [UInt8](repeating: 0, count: 8)
        report[0] = modifier
        report[2] = key
        let frame = HIDEncoder.frame(type: 0x01, payload: report)
        serial.send(frame: frame)
    }

    private func setupMouseTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.captureInput else { return }
            let dx = self.pendingDX; let dy = self.pendingDY
            let wx = self.pendingWheelX; let wy = self.pendingWheelY
            if dx == 0 && dy == 0 && wx == 0 && wy == 0 { return }
            // Clamp deltas to int8 range
            func clamp(_ v: Int) -> Int8 { return Int8(max(-127, min(127, v))) }
            let payload: [UInt8] = [self.currentButtons, UInt8(bitPattern: clamp(dx)), UInt8(bitPattern: clamp(dy)), UInt8(bitPattern: clamp(wy))]
            self.sendMouse(payload: payload)
            self.pendingDX = 0; self.pendingDY = 0; self.pendingWheelX = 0; self.pendingWheelY = 0
        }
        timer.resume()
        mouseTimer = timer
    }

    private func sendMouse(payload: [UInt8]) {
        let frame = HIDEncoder.frame(type: 0x02, payload: payload)
        serial.send(frame: frame)
    }
}
