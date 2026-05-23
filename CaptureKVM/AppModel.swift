import SwiftUI
import AppKit
import AVFoundation
import Combine
import CoreBluetooth

enum ConnectionMode: String, CaseIterable, Identifiable {
    case local = "Local"
    case remote = "Remote over IP"
    var id: String { rawValue }
}

enum TransportKind: String, CaseIterable, Identifiable {
    case usbSerial = "USB Serial"
    case bluetooth = "Bluetooth"
    var id: String { rawValue }
}

final class AppModel: ObservableObject {
    @Published var connectionMode: ConnectionMode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .local {
        didSet {
            guard oldValue != connectionMode else { return }
            if oldValue == .local {
                switch transportKind {
                case .usbSerial:
                    if serial.isConnected { serial.disconnect() }
                case .bluetooth:
                    if bluetooth.isConnected { bluetooth.disconnect() }
                    stopBLEScan()
                }
            } else {
                let baseURL = remoteBaseURL
                let token = remoteAuthToken
                let sessionID = remoteSessionID
                remoteSessionID = ""
                remoteInput.disconnect()
                if !baseURL.isEmpty, !token.isEmpty, !sessionID.isEmpty {
                    Task { await remoteControl.closeSession(baseURLString: baseURL, authToken: token, sessionID: sessionID) }
                }
            }
            isConnected = false
            captureInput = false
            UserDefaults.standard.set(connectionMode.rawValue, forKey: "connectionMode")
        }
    }

    // Video
    @Published var videoDevices: [CaptureDeviceInfo] = []
    @Published var selectedVideoUniqueID: String = ""

    // Serial
    @Published var serialPorts: [String] = []
    @Published var selectedSerialPath: String = ""
    @Published var isConnected: Bool = false
    @Published var lastSerialError: String = ""
    @Published var remoteBaseURL: String = UserDefaults.standard.string(forKey: "remoteBaseURL") ?? "" {
        didSet { UserDefaults.standard.set(remoteBaseURL, forKey: "remoteBaseURL") }
    }
    @Published var remoteAuthToken: String = UserDefaults.standard.string(forKey: "remoteAuthToken") ?? "" {
        didSet { UserDefaults.standard.set(remoteAuthToken, forKey: "remoteAuthToken") }
    }
    @Published var remoteSessionID: String = ""

    // Transport selection + Bluetooth
    @Published var transportKind: TransportKind = TransportKind(rawValue: UserDefaults.standard.string(forKey: "transportKind") ?? "") ?? .usbSerial {
        didSet {
            guard connectionMode == .local else { return }
            // Switching transports drops any live connection on the OLD transport so
            // isConnected always reflects the currently-selected transport's state.
            // Otherwise the selectors in the toolbar + Settings desync (e.g. user
            // disconnects BLE, switches to USB Serial, but bluetooth.isConnected is
            // still true from a previous attempt).
            if oldValue != transportKind {
                switch oldValue {
                case .usbSerial: if serial.isConnected { serial.disconnect() }
                case .bluetooth: if bluetooth.isConnected { bluetooth.disconnect() }
                }
            }
            UserDefaults.standard.set(transportKind.rawValue, forKey: "transportKind")
        }
    }
    @Published var blePeripherals: [BLEPeripheralInfo] = []
    @Published var selectedBLEPeripheralID: UUID? = nil
    /// When true, the next discovered KVM peripheral auto-connects (used by
    /// the Settings "Switch to Bluetooth & start pairing" orchestrator).
    private var pairingFlowActive: Bool = false

    // Paste-from-host state
    @Published var isPasting: Bool = false

    // Surfaced from the firmware over UART. Cached to UserDefaults so the Settings
    // window can still show the last-known PIN when we're not currently on USB.
    @Published var blePIN: String = (UserDefaults.standard.string(forKey: "lastBlePIN") ?? "") {
        didSet { UserDefaults.standard.set(blePIN, forKey: "lastBlePIN") }
    }
    /// True for a few seconds after the PIN was just copied to the clipboard
    /// (e.g. after Rotate PIN or starting the pair flow). UI uses this to show
    /// a transient "Copied" badge.
    @Published var pinCopiedToClipboard: Bool = false
    /// True when a rotate is pending and the next PIN we receive should be
    /// auto-copied to the clipboard.
    private var copyPinOnNextResponse: Bool = false
    /// True when blePIN was set by the live firmware (via GET_STATE) during this session.
    /// False if the value is just the cached one from a previous session.
    @Published var blePinIsLive: Bool = false
    @Published var bleRadioEnabled: Bool = true
    @Published var bleDeviceName: String = UserDefaults.standard.string(forKey: "lastBleName") ?? ""
    /// Target machine has enumerated the ESP32's USB HID. Unknown when on BLE.
    @Published var hidMountedOnTarget: Bool = false
    /// Some BLE central is connected to the ESP32 (we may not be the only one).
    @Published var bleClientConnected: Bool = false

    // Input capture toggle
    @Published var captureInput: Bool = false

    // Map host ⌘ to target Ctrl and host ⌃ to target Super. Useful for non-Mac targets.
    @Published var swapCmdCtrl: Bool = (UserDefaults.standard.object(forKey: "swapCmdCtrl") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(swapCmdCtrl, forKey: "swapCmdCtrl") }
    }

    // Managers
    let capture = CaptureManager()
    let serial = ESP32Serial()
    let bluetooth = BluetoothTransport()
    let remoteControl = RemoteControlAPI()
    let remoteInput = RemoteUDPInputSink()

    /// Direct switch dispatch on the hot path — no protocol witness call.
    private var transport: FrameTransport {
        switch transportKind {
        case .usbSerial: return serial
        case .bluetooth: return bluetooth
        }
    }

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

    /// Periodic state poll while connected via USB Serial so the status icons stay live.
    private var firmwareStatePollTimer: DispatchSourceTimer?
    private var remoteKeepAliveTimer: DispatchSourceTimer?

    init() {
        setupMouseTimer()
        setupVideoDeviceWatcher()
        setupSerialPollTimer()
        setupFirmwareStatePollTimer()
        setupRemoteKeepAliveTimer()
        let errHandler: (String) -> Void = { [weak self] message in
            DispatchQueue.main.async { self?.lastSerialError = message }
        }
        serial.onConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.connectionMode == .local else { return }
                self.isConnected = connected
                if !connected {
                    self.captureInput = false
                    self.blePinIsLive = false      // PIN value is now stale (cached)
                    self.hidMountedOnTarget = false
                    self.bleClientConnected = false
                } else {
                    self.requestFirmwareState()    // populate PIN + BLE state
                }
            }
        }
        serial.onError = errHandler
        serial.onPin = { [weak self] pin in
            DispatchQueue.main.async {
                guard let self else { return }
                self.blePIN = pin
                self.blePinIsLive = true
                if self.copyPinOnNextResponse {
                    self.copyPinOnNextResponse = false
                    self.copyPinToClipboard()
                }
            }
        }
        serial.onState = { [weak self] enabled, hidMounted, bleClient, pin, name in
            DispatchQueue.main.async {
                guard let self else { return }
                self.bleRadioEnabled = enabled
                self.hidMountedOnTarget = hidMounted
                self.bleClientConnected = bleClient
                if !pin.isEmpty { self.blePIN = pin }
                self.blePinIsLive = true
                if !name.isEmpty {
                    self.bleDeviceName = name
                    UserDefaults.standard.set(name, forKey: "lastBleName")
                }
            }
        }
        bluetooth.onConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.connectionMode == .local else { return }
                self.isConnected = connected
                if !connected { self.captureInput = false }
            }
        }
        bluetooth.onError = errHandler
        bluetooth.onDiscoveredPeripheralsChanged = { [weak self] list in
            DispatchQueue.main.async {
                guard let self else { return }
                self.blePeripherals = list
                // Convenience: while the user hasn't picked anything yet, auto-select
                // the first KVM-prefixed peripheral so the Connect button arms itself.
                if self.selectedBLEPeripheralID == nil, let first = list.first {
                    self.selectedBLEPeripheralID = first.id
                    // If the orchestrator started this scan, also kick off the connect
                    // so macOS prompts for the PIN immediately. PIN is already on the
                    // clipboard from startBluetoothPairFlow.
                    if self.pairingFlowActive {
                        self.pairingFlowActive = false
                        self.connect()
                    }
                }
            }
        }
        remoteInput.onConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.connectionMode == .remote else { return }
                self.isConnected = connected
                if !connected { self.captureInput = false }
            }
        }
        remoteInput.onError = errHandler
    }

    deinit {
        if let o = deviceConnectObserver { NotificationCenter.default.removeObserver(o) }
        if let o = deviceDisconnectObserver { NotificationCenter.default.removeObserver(o) }
        serialPollTimer?.cancel()
        firmwareStatePollTimer?.cancel()
        remoteKeepAliveTimer?.cancel()
        mouseTimer?.cancel()
    }

    // MARK: - UI helpers
    var captureStatusOK: Bool { connectionMode == .local && capture.isRunning }
    var captureStatusText: String {
        if connectionMode == .remote {
            return "Remote video receiver not wired yet"
        }
        return capture.isRunning ? "Video OK" : "No Video"
    }
    var serialStatusText: String {
        if connectionMode == .remote {
            return isConnected ? remoteInput.statusDescription : "Remote agent disconnected"
        }
        return isConnected ? transport.statusDescription : "ESP32 Disconnected"
    }

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
            if connectionMode == .local, isConnected { disconnect() }
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

    private func setupFirmwareStatePollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.transportKind == .usbSerial, self.isConnected {
                self.requestFirmwareState()
            }
        }
        timer.resume()
        firmwareStatePollTimer = timer
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

    private func setupRemoteKeepAliveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.connectionMode == .remote, self.isConnected, !self.remoteSessionID.isEmpty else { return }
            let baseURL = self.remoteBaseURL
            let token = self.remoteAuthToken
            let sessionID = self.remoteSessionID
            Task {
                do {
                    try await self.remoteControl.keepAlive(baseURLString: baseURL, authToken: token, sessionID: sessionID)
                } catch {
                    await MainActor.run {
                        self.lastSerialError = "Remote keepalive failed: \(error.localizedDescription)"
                    }
                }
            }
        }
        timer.resume()
        remoteKeepAliveTimer = timer
    }

    func connect() {
        lastSerialError = ""
        if connectionMode == .remote {
            connectRemote()
            return
        }
        switch transportKind {
        case .usbSerial:
            guard !selectedSerialPath.isEmpty else { return }
            serial.connect(path: selectedSerialPath)
        case .bluetooth:
            guard let id = selectedBLEPeripheralID else { return }
            bluetooth.connect(peripheralID: id)
        }
    }

    func disconnect() {
        if connectionMode == .remote {
            let baseURL = remoteBaseURL
            let token = remoteAuthToken
            let sessionID = remoteSessionID
            remoteSessionID = ""
            remoteInput.disconnect()
            captureInput = false
            if !baseURL.isEmpty, !token.isEmpty, !sessionID.isEmpty {
                Task { await remoteControl.closeSession(baseURLString: baseURL, authToken: token, sessionID: sessionID) }
            }
            return
        }
        transport.disconnect()
    }

    func startBLEScan()  { bluetooth.startScan() }
    func stopBLEScan()   { bluetooth.stopScan()  }

    // MARK: - Firmware management commands (UART-only)

    private func sendCommand(_ type: UInt8, payload: [UInt8] = []) {
        guard connectionMode == .local, transportKind == .usbSerial, isConnected else { return }
        let frame = HIDEncoder.frame(type: type, payload: payload)
        serial.send(frame: frame)
    }

    func requestFirmwareState() { sendCommand(0x85) }  // GET_STATE
    func requestBlePin()        { sendCommand(0x81) }  // GET_PIN
    func rotateBlePin() {
        // Optimistic clear so the UI doesn't briefly show the old PIN; the new value
        // will arrive in the follow-up state response, and we'll auto-copy it to the
        // clipboard so the user can paste it into macOS' pairing prompt.
        blePIN = ""
        blePinIsLive = false
        copyPinOnNextResponse = true
        sendCommand(0x82)
    }
    func setBleRadioEnabled(_ enabled: Bool) {
        // Optimistic update so the SwiftUI Toggle stays in the new position rather
        // than snapping back while we wait for the firmware's state response.
        bleRadioEnabled = enabled
        sendCommand(enabled ? 0x83 : 0x84)
    }

    // MARK: - Bluetooth pair orchestration

    /// One-shot helper used by the Settings window's "Pair Bluetooth" button.
    /// - Disconnects whatever's currently connected.
    /// - Copies the current PIN to the clipboard (so the user can paste it into
    ///   macOS' pairing prompt without leaving Settings or memorising digits).
    /// - Switches to the Bluetooth transport.
    /// - Starts a scan; the discovery handler will auto-select the first KVM
    ///   bridge it sees and (because we set `pairingFlowActive`) auto-initiate
    ///   the BLE connect — which is what triggers macOS' pairing dialog.
    func startBluetoothPairFlow() {
        if isConnected { disconnect() }
        if connectionMode != .local { connectionMode = .local }
        selectedBLEPeripheralID = nil
        if !blePIN.isEmpty { copyPinToClipboard() }
        pairingFlowActive = true
        transportKind = .bluetooth
        startBLEScan()
    }

    /// Puts the current PIN on the pasteboard and flips `pinCopiedToClipboard`
    /// on for 2 s so the Settings UI can show a "Copied" badge.
    func copyPinToClipboard() {
        guard !blePIN.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(blePIN, forType: .string)
        pinCopiedToClipboard = true
        let work = DispatchWorkItem { [weak self] in self?.pinCopiedToClipboard = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
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
        if flags.contains(.shift)  { mod |= 0x02 }
        if flags.contains(.option) { mod |= 0x04 }
        if swapCmdCtrl {
            // Cross-OS friendly: host ⌘ -> target Ctrl, host ⌃ -> target Super.
            if flags.contains(.command) { mod |= 0x01 }
            if flags.contains(.control) { mod |= 0x08 }
        } else {
            if flags.contains(.control) { mod |= 0x01 }
            if flags.contains(.command) { mod |= 0x08 }
        }
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
        if connectionMode == .remote {
            remoteInput.sendKeyboardReport(report)
        } else {
            let frame = HIDEncoder.frame(type: 0x01, payload: report)
            transport.send(frame: frame)
        }
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
        if connectionMode == .remote {
            remoteInput.sendKeyboardReport(report)
        } else {
            let frame = HIDEncoder.frame(type: 0x01, payload: report)
            transport.send(frame: frame)
        }
    }

    private func setupMouseTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 4 ms ≈ 250 Hz, just above typical mouse polling rates; lower than this
        // would saturate the boot HID 1 ms polling interval on the target.
        timer.schedule(deadline: .now() + .milliseconds(4), repeating: .milliseconds(4))
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
        if connectionMode == .remote {
            remoteInput.sendMouseReport(payload)
        } else {
            let frame = HIDEncoder.frame(type: 0x02, payload: payload)
            transport.send(frame: frame)
        }
    }

    private func connectRemote() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.remoteControl.createSession(
                    baseURLString: self.remoteBaseURL,
                    authToken: self.remoteAuthToken
                )
                try await self.remoteInput.connect(configuration: .init(
                    host: session.udpHost,
                    port: session.inputPort,
                    sessionID: session.sessionID,
                    sessionKey: session.sessionKey,
                    mtu: session.mtu
                ))
                await MainActor.run {
                    self.remoteSessionID = session.rawSessionID
                    self.lastSerialError = ""
                }
            } catch {
                await MainActor.run {
                    self.remoteSessionID = ""
                    self.lastSerialError = "Remote connect failed: \(error.localizedDescription)"
                    self.remoteInput.disconnect()
                }
            }
        }
    }
}
