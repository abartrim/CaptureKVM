import SwiftUI

/// Standard macOS Settings window (⌘,). All "set once and forget" controls live here,
/// plus an orchestrated Bluetooth pairing flow.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var flasher = FirmwareFlasher()

    var body: some View {
        TabView {
            keyboardTab
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            remoteTab
                .tabItem { Label("Remote", systemImage: "network") }
            bluetoothTab
                .tabItem { Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right") }
            firmwareTab
                .tabItem { Label("Firmware", systemImage: "cpu") }
        }
        .frame(width: 560, height: 440)
    }

    // MARK: - Keyboard tab

    private var keyboardTab: some View {
        Form {
            Toggle("Swap ⌘ ↔ ⌃ when sending modifiers", isOn: $model.swapCmdCtrl)
            Text("When enabled, the host's Command key is sent to the target as Control, and the host's Control is sent as Super (Windows key). Recommended for Linux and Windows targets so ⌘C / ⌘V / ⌘Tab behave the way you'd expect on the target.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }

    private var remoteTab: some View {
        Form {
            Section {
                Picker("Mode", selection: $model.connectionMode) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } header: { Text("Connection mode") }

            Section {
                TextField("http://capturekvm.local:8080", text: $model.remoteBaseURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Auth token", text: $model.remoteAuthToken)
                    .textFieldStyle(.roundedBorder)
            } header: { Text("Remote agent") } footer: {
                Text("These values are only used in Remote over IP mode. The auth token is sent to the agent's HTTP control plane, and the returned UDP session key is then used to encrypt keyboard and mouse packets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Session") {
                    Text(model.remoteSessionID.isEmpty ? "—" : model.remoteSessionID)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Link") {
                    Text(model.serialStatusText)
                        .foregroundStyle(model.isConnected ? .primary : .secondary)
                }
            } header: { Text("Status") }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }

    // MARK: - Bluetooth tab

    private var bluetoothTab: some View {
        Form {
            Section {
                usbConnectionRow
            } header: { Text("USB Serial connection") } footer: {
                Text("Connect to the bridge over USB Serial right here — no need to bounce back to the main window — so you can read or rotate the PIN, change the radio state, or kick off the pair flow without leaving Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                pinRow
                rotateButton
            } header: { Text("Pairing PIN") } footer: {
                Text("BLE writes require LE Secure Connections pairing with this PIN. Once paired, the bond is stored in macOS' keychain. The PIN is shown live when connected via USB Serial; otherwise the last value seen on this Mac is shown for reference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                pairBluetoothButton
            } header: { Text("Pair with Bluetooth") } footer: {
                Text("Disconnects USB, copies the PIN to your clipboard, switches the Link to Bluetooth, scans, auto-selects the first KVM bridge, and initiates the connection — which triggers macOS' pairing dialog. Just paste the PIN (⌘V) in the dialog. If you rotated the PIN, you may need to **Forget** the device in System Settings → Bluetooth first so macOS doesn't try to use the stale bond.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                radioToggle
            } header: { Text("Radio") } footer: {
                Text("Turn the ESP32's BLE radio off entirely (hardware-only mode). Setting persists across reboots. Only changeable while connected via USB Serial — physical presence required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }

    private var pinRow: some View {
        LabeledContent("PIN") {
            HStack(spacing: 8) {
                Text(model.blePIN.isEmpty ? "—" : model.blePIN)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                if !model.blePIN.isEmpty {
                    Button {
                        model.copyPinToClipboard()
                    } label: {
                        Image(systemName: model.pinCopiedToClipboard ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(model.pinCopiedToClipboard ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy PIN to clipboard so it's ready to paste into macOS' pairing prompt.")
                }
                statusBadge
            }
        }
    }

    private var statusBadge: some View {
        Group {
            if model.blePIN.isEmpty {
                Label("Unknown", systemImage: "questionmark.circle")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            } else if model.blePinIsLive {
                Label("Live", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                Label("Cached — connect via USB to refresh", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    private var rotateButton: some View {
        HStack {
            Button("Rotate PIN…", role: .destructive) { model.rotateBlePin() }
                .disabled(!canManage)
            if !canManage {
                Text("Connect via USB Serial to rotate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("Generates a fresh random PIN, clears any existing BLE bonds, and persists the new PIN on the ESP32. Bonded Macs will need to re-pair.")
    }

    private var pairBluetoothButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.startBluetoothPairFlow()
            } label: {
                Label("Switch to Bluetooth & start pairing", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(model.blePIN.isEmpty)
            if model.blePIN.isEmpty {
                Text("Connect via USB Serial at least once so the PIN is known.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Have the PIN handy: **\(model.blePIN)** — macOS will prompt for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var radioToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("BLE radio enabled", isOn: Binding(
                get: { model.bleRadioEnabled },
                set: { model.setBleRadioEnabled($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!canManage)
            if !canManage {
                Text("Connect via USB Serial to change the radio state.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var canManage: Bool {
        model.connectionMode == .local && model.isConnected && model.transportKind == .usbSerial
    }

    private var usbConnectionRow: some View {
        HStack {
            Picker("Port", selection: $model.selectedSerialPath) {
                Text("— Select —").tag("")
                ForEach(model.serialPorts, id: \.self) { p in Text(p).tag(p) }
            }
            .frame(maxWidth: 240)
            .disabled(canManage)

            Spacer()

            Button(canManage ? "Disconnect" : "Connect") {
                if canManage {
                    model.disconnect()
                } else {
                    if model.connectionMode != .local { model.connectionMode = .local }
                    if model.transportKind != .usbSerial { model.transportKind = .usbSerial }
                    model.connect()
                }
            }
            .disabled(model.selectedSerialPath.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Firmware tab

    private var firmwareTab: some View {
        Form {
            Section {
                LabeledContent("Port") {
                    Picker("", selection: $model.selectedSerialPath) {
                        Text("— Select —").tag("")
                        ForEach(model.serialPorts, id: \.self) { p in Text(p).tag(p) }
                    }
                    .labelsHidden()
                }

                HStack {
                    Button {
                        if model.isConnected, model.transportKind == .usbSerial {
                            model.disconnect()
                        }
                        flasher.start(port: model.selectedSerialPath)
                    } label: {
                        if flasher.isFlashing {
                            Label("Flashing… \(flasher.progressPercent)%",
                                  systemImage: "arrow.triangle.2.circlepath")
                        } else if flasher.isVerifying {
                            Label("Verifying…", systemImage: "checkmark.bubble")
                        } else {
                            Label("Flash bundled firmware", systemImage: "memorychip")
                        }
                    }
                    .disabled(model.selectedSerialPath.isEmpty || flasher.isFlashing || flasher.isVerifying)

                    Spacer()
                    if flasher.isFlashing || flasher.isVerifying {
                        ProgressView(value: Double(flasher.progressPercent), total: 100)
                            .frame(width: 140)
                    }
                }

                if flasher.lastSuccess {
                    Label("Flash + verify succeeded. ESP32 is running the new firmware.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let err = flasher.lastError, !err.isEmpty {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !flasher.lastLogLine.isEmpty {
                    Text(flasher.lastLogLine)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Bundled firmware")
            } footer: {
                Text("Flashes the firmware that ships with this version of the Mac app to the ESP32 over the selected USB-COM port. Any existing serial connection is closed first. Takes ~10 seconds at 460 800 baud. The ESP32 hard-resets when complete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }
}

#Preview {
    SettingsView(model: AppModel())
}
