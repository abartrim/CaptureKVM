import Foundation
import Network
import CryptoKit

final class RemoteUDPInputSink {
    struct Configuration {
        let host: String
        let port: UInt16
        let sessionID: UInt64
        let sessionKey: Data
        let mtu: Int
    }

    private enum Constants {
        static let magic: [UInt8] = [0x43, 0x4B, 0x56, 0x4D]
        static let protocolVersion: UInt8 = 1
        static let directionClientToServer: UInt8 = 0x01
        static let headerBytes = 30
        static let gcmTagBytes = 16
        static let packetKindKeyboard: UInt8 = 0x01
        static let packetKindMouse: UInt8 = 0x02
        static let packetKindPing: UInt8 = 0x03
    }

    private let queue = DispatchQueue(label: "CaptureKVM.remote.udp", qos: .userInteractive)
    private var connection: NWConnection?
    private var configuration: Configuration?
    private var sequence: UInt32 = 0
    private(set) var isConnected: Bool = false

    var onConnectionChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    var statusDescription: String {
        guard let configuration else { return "Remote UDP disconnected" }
        return isConnected ? "Remote UDP @ \(configuration.host):\(configuration.port)" : "Remote UDP connecting"
    }

    func connect(configuration: Configuration) async throws {
        disconnect()
        self.configuration = configuration
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw RemoteControlAPIError.invalidResponse
        }

        let connection = NWConnection(host: NWEndpoint.Host(configuration.host), port: port, using: .udp)
        self.connection = connection

        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.onConnectionChanged?(true)
                    self.sendPing()
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                case .failed(let error):
                    self.isConnected = false
                    self.onConnectionChanged?(false)
                    self.onError?("Remote UDP failed: \(error.localizedDescription)")
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    self.isConnected = false
                    self.onConnectionChanged?(false)
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        configuration = nil
        sequence = 0
        if isConnected {
            isConnected = false
            onConnectionChanged?(false)
        }
    }

    func sendKeyboardReport(_ report: [UInt8]) {
        sendPacket(kind: Constants.packetKindKeyboard, payload: Data(report))
    }

    func sendMouseReport(_ report: [UInt8]) {
        sendPacket(kind: Constants.packetKindMouse, payload: Data(report))
    }

    func sendPing() {
        sendPacket(kind: Constants.packetKindPing, payload: Data())
    }

    private func sendPacket(kind: UInt8, payload: Data) {
        guard let connection, let configuration else { return }
        guard payload.count + Constants.headerBytes + Constants.gcmTagBytes <= configuration.mtu else {
            onError?("Remote UDP payload exceeds negotiated MTU.")
            return
        }

        do {
            sequence &+= 1
            let header = makeHeader(kind: kind, sessionID: configuration.sessionID, sequence: sequence, payloadLength: payload.count)
            let sealed = try AES.GCM.seal(
                payload,
                using: SymmetricKey(data: configuration.sessionKey),
                nonce: try AES.GCM.Nonce(data: makeNonce(sessionID: configuration.sessionID, sequence: sequence)),
                authenticating: header
            )
            var packet = header
            packet.append(sealed.ciphertext)
            packet.append(sealed.tag)
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.onError?("Remote UDP send failed: \(error.localizedDescription)")
                }
            })
        } catch {
            onError?("Remote UDP crypto failed: \(error.localizedDescription)")
        }
    }

    private func makeHeader(kind: UInt8, sessionID: UInt64, sequence: UInt32, payloadLength: Int) -> Data {
        var data = Data()
        data.append(contentsOf: Constants.magic)
        data.append(Constants.protocolVersion)
        data.append(kind)
        data.append(contentsOf: [0x00, 0x00])
        data.append(bigEndianBytes(sessionID))
        data.append(bigEndianBytes(sequence))
        data.append(bigEndianBytes(UInt64(Date().timeIntervalSince1970 * 1_000_000)))
        data.append(bigEndianBytes(UInt16(payloadLength)))
        return data
    }

    private func makeNonce(sessionID: UInt64, sequence: UInt32) -> Data {
        let sessionBytes = bigEndianBytes(sessionID)
        var nonce = Data()
        nonce.append(contentsOf: sessionBytes.dropFirst())
        nonce.append(Constants.directionClientToServer)
        nonce.append(bigEndianBytes(sequence))
        return nonce
    }

    private func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}
