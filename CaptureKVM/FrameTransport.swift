import Foundation

/// Common surface for any transport that can shuttle COBS+CRC8 frames to the ESP32 bridge.
/// Currently implemented by `ESP32Serial` (UART via USB-UART bridge) and `BluetoothTransport`
/// (BLE GATT writes). Methods are synchronous on the hot path so per-frame send overhead
/// stays in the single-digit microseconds.
protocol FrameTransport: AnyObject {
    /// Whether the transport currently has a live link to the device.
    var isConnected: Bool { get }

    /// Human-readable description of the active link (e.g. `"ESP32 @ 921600"`,
    /// `"BLE: ESP32 KVM HID Bridge"`). Used by the toolbar status label.
    var statusDescription: String { get }

    /// Fired on any state transition; argument is the new `isConnected` value.
    var onConnectionChanged: ((Bool) -> Void)? { get set }

    /// Fired when a connection attempt fails (or an in-flight error occurs).
    var onError: ((String) -> Void)? { get set }

    /// Sends a fully-framed packet (COBS-encoded with terminator).
    func send(frame: Data)

    /// Tears down the current connection if any.
    func disconnect()
}
