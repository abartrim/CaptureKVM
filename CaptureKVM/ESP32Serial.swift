import Foundation
import Darwin
import os

private let serialLog = Logger(subsystem: "Trustonica.CaptureKVM", category: "ESP32Serial")

final class ESP32Serial: FrameTransport {
    private var fd: Int32 = -1
    private(set) var negotiatedBaud: Int = 0
    var onConnectionChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    // Framed-response callbacks (UART only; PIN/state management).
    var onPin: ((String) -> Void)?
    var onState: ((_ bleEnabled: Bool, _ hidMounted: Bool, _ bleClient: Bool, _ pin: String, _ name: String) -> Void)?

    var isConnected: Bool { fd >= 0 }
    var statusDescription: String {
        guard isConnected else { return "ESP32 Disconnected" }
        return negotiatedBaud > 0 ? "ESP32 @ \(negotiatedBaud)" : "ESP32 Connected"
    }

    // Tried high-to-low. The firmware writes a single 0xAA back when it sees a
    // FRAME_TYPE_PING (0x80) frame; whichever baud the pong arrives on, we keep.
    private static let baudCandidates: [Int] = [921600, 460800, 230400, 115200]
    private static let pongByte: UInt8 = 0xAA
    private static let probeTimeoutMs: Int = 150

    // Read loop state — populated after a successful baud negotiation.
    private var readSource: DispatchSourceRead?
    private var rxBuffer: [UInt8] = []
    private let maxFrameLen = 32

    static func availablePorts() -> [String] {
        let patterns = ["/dev/cu.usb*", "/dev/cu.SLAB*", "/dev/cu.wchusbserial*"]
        var results: [String] = []
        for p in patterns {
            let matches = globPaths(pattern: p)
            results.append(contentsOf: matches)
        }
        return Array(Set(results)).sorted()
    }

    func connect(path: String) {
        disconnect()
        serialLog.info("connect attempting open: \(path, privacy: .public)")
        let flags: Int32 = O_RDWR | O_NOCTTY | O_NONBLOCK
        let fd = open(path, flags)
        if fd < 0 {
            let err = errno
            let msg = "open(\(path)) failed: errno=\(err) (\(String(cString: strerror(err))))"
            serialLog.error("\(msg, privacy: .public)")
            onError?(msg)
            return
        }

        var tio = termios()
        if tcgetattr(fd, &tio) != 0 {
            let err = errno
            let msg = "tcgetattr failed: errno=\(err) (\(String(cString: strerror(err))))"
            serialLog.error("\(msg, privacy: .public)")
            onError?(msg)
            close(fd)
            return
        }
        cfmakeraw(&tio)
        tio.c_cflag |= (tcflag_t(CLOCAL) | tcflag_t(CREAD))
        tio.c_cflag &= ~tcflag_t(CRTSCTS)

        let pingFrame = HIDEncoder.frame(type: 0x80, payload: [])

        for baud in ESP32Serial.baudCandidates {
            cfsetispeed(&tio, speed_t(baud))
            cfsetospeed(&tio, speed_t(baud))
            if tcsetattr(fd, TCSANOW, &tio) != 0 { continue }
            tcflush(fd, TCIOFLUSH)

            pingFrame.withUnsafeBytes { buf in
                _ = Darwin.write(fd, buf.baseAddress, buf.count)
            }

            if waitForPong(fd: fd, timeoutMs: ESP32Serial.probeTimeoutMs) {
                self.fd = fd
                self.negotiatedBaud = baud
                serialLog.info("connected to \(path, privacy: .public) at \(baud) baud")
                startReadLoop()
                onConnectionChanged?(true)
                return
            }
        }

        let msg = "No response from ESP32 at any baud. Confirm firmware is flashed and matches this app version."
        serialLog.error("\(msg, privacy: .public)")
        onError?(msg)
        close(fd)
    }

    func disconnect() {
        readSource?.cancel()
        readSource = nil
        rxBuffer.removeAll()
        if fd >= 0 {
            close(fd)
            fd = -1
            negotiatedBaud = 0
            onConnectionChanged?(false)
        }
    }

    func send(frame: Data) {
        guard fd >= 0 else { return }
        frame.withUnsafeBytes { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }

    // MARK: - Read loop + framed response parsing

    private func startReadLoop() {
        guard fd >= 0 else { return }
        readSource?.cancel()
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            self?.drainAndParse()
        }
        src.resume()
        readSource = src
    }

    private func drainAndParse() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 128)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            Darwin.read(fd, ptr.baseAddress, ptr.count)
        }
        guard n > 0 else { return }
        for i in 0..<Int(n) {
            let b = buf[i]
            if b == 0x00 {
                finalizeRxFrame()
            } else {
                if rxBuffer.count >= maxFrameLen {
                    rxBuffer.removeAll()  // overflow; resync
                } else {
                    rxBuffer.append(b)
                }
            }
        }
    }

    private func finalizeRxFrame() {
        defer { rxBuffer.removeAll(keepingCapacity: true) }
        guard !rxBuffer.isEmpty else { return }
        guard let decoded = HIDEncoder.cobsDecode(rxBuffer), decoded.count >= 2 else { return }
        let crc = decoded.last!
        let payload = Array(decoded.dropLast())
        guard HIDEncoder.crc8(data: payload) == crc else { return }
        let type = payload[0]
        let body = Array(payload.dropFirst())
        handleResponseFrame(type: type, payload: body)
    }

    private func handleResponseFrame(type: UInt8, payload: [UInt8]) {
        switch type {
        case 0x81, 0x82:  // GET_PIN response / ROTATE_PIN response
            if payload.count >= 6,
               let pin = String(bytes: payload.prefix(6), encoding: .ascii) {
                onPin?(pin)
            }
        case 0x85:  // GET_STATE: [bleEnabled(1), hidMounted(1), bleClient(1), pin(6 ASCII), name...]
            guard payload.count >= 9 else { return }
            let bleEnabled = payload[0] != 0
            let hidMounted = payload[1] != 0
            let bleClient  = payload[2] != 0
            guard let pin = String(bytes: payload[3..<9], encoding: .ascii) else { return }
            let nameBytes = Array(payload.dropFirst(9))
            let name = String(bytes: nameBytes, encoding: .utf8) ?? ""
            onState?(bleEnabled, hidMounted, bleClient, pin, name)
        default:
            break
        }
    }

    /// Polls the fd for `pongByte` until timeout.
    private func waitForPong(fd: Int32, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        var byte: UInt8 = 0
        while Date() < deadline {
            let n = Darwin.read(fd, &byte, 1)
            if n == 1 && byte == ESP32Serial.pongByte { return true }
            if n < 0 && errno != EAGAIN { return false }
            usleep(2000)
        }
        return false
    }
}

// MARK: - POSIX helpers

private func globPaths(pattern: String) -> [String] {
    var g = glob_t()
    let flags = GLOB_TILDE | GLOB_BRACE | GLOB_MARK
    let rv = pattern.withCString { cstr in glob(cstr, flags, nil, &g) }
    guard rv == 0 else { return [] }
    defer { globfree(&g) }
    var results: [String] = []
    for i in 0..<Int(g.gl_matchc) {
        if let path = g.gl_pathv[i] { results.append(String(cString: path)) }
    }
    return results
}
