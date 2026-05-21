import Foundation
import Darwin
import os

private let serialLog = Logger(subsystem: "Trustonica.CaptureKVM", category: "ESP32Serial")

final class ESP32Serial {
    private var fd: Int32 = -1
    var onConnectionChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

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
        cfsetispeed(&tio, speed_t(B115200))
        cfsetospeed(&tio, speed_t(B115200))
        tio.c_cflag |= (tcflag_t(CLOCAL) | tcflag_t(CREAD))
        tio.c_cflag &= ~tcflag_t(CRTSCTS)
        if tcsetattr(fd, TCSANOW, &tio) != 0 {
            let err = errno
            let msg = "tcsetattr failed: errno=\(err) (\(String(cString: strerror(err))))"
            serialLog.error("\(msg, privacy: .public)")
            onError?(msg)
            close(fd)
            return
        }
        self.fd = fd
        serialLog.info("connect succeeded fd=\(fd)")
        onConnectionChanged?(true)
    }

    func disconnect() {
        if fd >= 0 { close(fd); fd = -1; onConnectionChanged?(false) }
    }

    func send(frame: Data) {
        guard fd >= 0 else { return }
        frame.withUnsafeBytes { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
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
