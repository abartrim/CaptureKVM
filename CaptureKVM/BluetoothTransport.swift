import Foundation
import CoreBluetooth
import os

private let bleLog = Logger(subsystem: "Trustonica.CaptureKVM", category: "BluetoothTransport")

/// 128-bit UUIDs for the custom GATT service exposed by the firmware.
/// Both ends hardcode these so the Mac scan can filter quickly.
enum BLEUUIDs {
    static let service       = CBUUID(string: "C0FFEE00-CAFE-4001-A001-BEEFD00DBEEF")
    static let frameWrite    = CBUUID(string: "C0FFEE01-CAFE-4001-A001-BEEFD00DBEEF") // host -> device
    static let frameNotify   = CBUUID(string: "C0FFEE02-CAFE-4001-A001-BEEFD00DBEEF") // device -> host (pong / future telemetry)
}

/// One discovered peripheral. Used by the SwiftUI picker.
struct BLEPeripheralInfo: Identifiable, Hashable {
    let id: UUID
    let name: String
}

final class BluetoothTransport: NSObject, FrameTransport {
    var onConnectionChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onPong: (() -> Void)?
    var onDiscoveredPeripheralsChanged: (([BLEPeripheralInfo]) -> Void)?

    private(set) var isConnected: Bool = false
    private(set) var connectedPeripheralName: String = ""
    var statusDescription: String {
        isConnected ? "BLE: \(connectedPeripheralName)" : "BLE Disconnected"
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var discovered: [UUID: BLEPeripheralInfo] = [:]
    private var pendingConnect: UUID?
    private var isScanning = false

    override init() {
        super.init()
        // Defer Bluetooth init until the user actually picks the BLE transport;
        // otherwise CoreBluetooth shows the "this app wants to use Bluetooth" prompt
        // on every launch.
    }

    /// Lazily spin up CBCentralManager. Safe to call repeatedly.
    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: nil)
        }
    }

    func startScan() {
        ensureCentral()
        guard let central, central.state == .poweredOn else {
            isScanning = true // we'll try again on state change
            return
        }
        if !central.isScanning {
            discovered.removeAll()
            onDiscoveredPeripheralsChanged?([])
            central.scanForPeripherals(withServices: [BLEUUIDs.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            bleLog.info("scan started")
        }
        isScanning = true
    }

    func stopScan() {
        isScanning = false
        guard let central, central.isScanning else { return }
        central.stopScan()
    }

    func connect(peripheralID: UUID) {
        ensureCentral()
        pendingConnect = peripheralID
        guard let central else { return }
        // If we already know the peripheral, connect immediately.
        if let p = central.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            stopScan()
            peripheral = p
            p.delegate = self
            central.connect(p, options: nil)
            return
        }
        // Otherwise scan briefly so we can pick it up.
        startScan()
    }

    func disconnect() {
        if let p = peripheral, let central {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        if isConnected {
            isConnected = false
            onConnectionChanged?(false)
        }
    }

    func send(frame: Data) {
        guard let peripheral, let writeChar, isConnected else { return }
        // Write Without Response = fire-and-forget; aligns with our UART hot path.
        peripheral.writeValue(frame, for: writeChar, type: .withoutResponse)
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bleLog.info("central poweredOn")
            if isScanning { startScan() }
            if let pid = pendingConnect { connect(peripheralID: pid) }
        case .unauthorized:
            onError?("Bluetooth permission denied. Allow in System Settings.")
        case .poweredOff:
            onError?("Bluetooth is off.")
        case .unsupported:
            onError?("Bluetooth is not supported on this Mac.")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown"
        discovered[id] = BLEPeripheralInfo(id: id, name: name)
        onDiscoveredPeripheralsChanged?(Array(discovered.values).sorted { $0.name < $1.name })

        if let pending = pendingConnect, pending == id {
            stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        bleLog.info("connected: \(peripheral.identifier.uuidString, privacy: .public)")
        connectedPeripheralName = peripheral.name ?? "ESP32 KVM HID Bridge"
        peripheral.discoverServices([BLEUUIDs.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        bleLog.error("connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        onError?("Bluetooth connect failed: \(error?.localizedDescription ?? "unknown")")
        if isConnected {
            isConnected = false
            onConnectionChanged?(false)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        bleLog.info("disconnected")
        self.peripheral = nil
        writeChar = nil
        notifyChar = nil
        if isConnected {
            isConnected = false
            onConnectionChanged?(false)
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            onError?("BLE discoverServices failed: \(error?.localizedDescription ?? "no services")")
            return
        }
        for svc in services where svc.uuid == BLEUUIDs.service {
            peripheral.discoverCharacteristics([BLEUUIDs.frameWrite, BLEUUIDs.frameNotify], for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else {
            onError?("BLE discoverCharacteristics failed: \(error?.localizedDescription ?? "")")
            return
        }
        for ch in chars {
            if ch.uuid == BLEUUIDs.frameWrite { writeChar = ch }
            if ch.uuid == BLEUUIDs.frameNotify {
                notifyChar = ch
                peripheral.setNotifyValue(true, for: ch)
            }
        }
        // Try the larger MTU; firmware will negotiate down if it doesn't agree.
        peripheral.maximumWriteValueLength(for: .withoutResponse)
        if writeChar != nil {
            isConnected = true
            onConnectionChanged?(true)
        } else {
            onError?("BLE: write characteristic not found on device.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Pong byte (or future telemetry) lands here.
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == BLEUUIDs.frameNotify {
            for byte in value where byte == 0xAA {
                onPong?()
            }
        }
    }
}
