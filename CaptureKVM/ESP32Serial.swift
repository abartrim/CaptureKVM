import Foundation
import Darwin
import os

private let serialLog = Logger(subsystem: "Trustonica.CaptureKVM", category: "ESP32Serial")

final class ESP32Serial {
    private var fd: Int32 = -1
    private(set) var negotiatedBaud: Int = 0
    var onConnectionChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    // Tried high-to-low. The firmware writes a single 0xAA back when it sees a
    // FRAME_TYPE_PING (0x80) frame; whichever baud the pong arrives on, we keep.
    private static let baudCandidates: [Int] = [921600, 460800, 230400, 115200]
    private static let pongByte: UInt8 = 0xAA
    private static let probeTimeoutMs: Int = 150

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

        // Build a single COBS+CRC8 ping frame; reused at every baud attempt.
        let pingFrame = HIDEncoder.frame(type: 0x80, payload: [])

        for baud in ESP32Serial.baudCandidates {
            cfsetispeed(&tio, speed_t(baud))
            cfsetospeed(&tio, speed_t(baud))
            if tcsetattr(fd, TCSANOW, &tio) != 0 { continue }
            // Discard any garbage that arrived at the previous baud.
            tcflush(fd, TCIOFLUSH)

            pingFrame.withUnsafeBytes { buf in
                _ = Darwin.write(fd, buf.baseAddress, buf.count)
            }

            if waitForPong(fd: fd, timeoutMs: ESP32Serial.probeTimeoutMs) {
                self.fd = fd
                self.negotiatedBaud = baud
                serialLog.info("connected to \(path, privacy: .public) at \(baud) baud")
                onConnectionChanged?(true)
                return
            }
        }

        // All bauds failed.
        let msg = "No response from ESP32 at any baud. Confirm firmware is flashed and matches this app version."
        serialLog.error("\(msg, privacy: .public)")
        onError?(msg)
        close(fd)
    }

    func disconnect() {
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

    /// Polls the fd for `pongByte` until timeout. Non-blocking reads + short usleep keep CPU low.
    private func waitForPong(fd: Int32, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        var byte: UInt8 = 0
        while Date() < deadline {
            let n = Darwin.read(fd, &byte, 1)
            if n == 1 && byte == ESP32Serial.pongByte { return true }
            if n < 0 && errno != EAGAIN { return false }
            usleep(2000) // 2 ms
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
