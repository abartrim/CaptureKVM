import Foundation
import Darwin
import SwiftUI
import Combine
import os

private let flashLog = Logger(subsystem: "Trustonica.CaptureKVM", category: "FirmwareFlasher")

/// Drives the bundled `esptool` binary to flash the bundled firmware image
/// to the connected ESP32-S3 over its UART bridge. Lives in its own type so
/// the SettingsView only has to call `start()` and observe the published
/// progress/log values.
@MainActor
final class FirmwareFlasher: ObservableObject {
    @Published private(set) var isFlashing: Bool = false
    @Published private(set) var isVerifying: Bool = false
    @Published private(set) var progressPercent: Int = 0
    @Published private(set) var lastLogLine: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var lastSuccess: Bool = false

    private var process: Process?
    private var stdoutBuffer: String = ""
    private var portInUse: String = ""

    /// Flashes the bundled firmware to the given POSIX serial path (e.g.
    /// `/dev/cu.usbmodemXXXX`). The caller is responsible for closing any
    /// existing serial connection on that port first.
    func start(port: String) {
        guard !isFlashing, !isVerifying else { return }
        isFlashing = true
        isVerifying = false
        progressPercent = 0
        lastLogLine = ""
        lastError = nil
        lastSuccess = false
        stdoutBuffer = ""
        portInUse = port

        do {
            try launch(port: port)
        } catch {
            isFlashing = false
            lastError = "\(error)"
            flashLog.error("launch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        isFlashing = false
    }

    // MARK: - Internals

    private func launch(port: String) throws {
        let fm = FileManager.default
        let bundle = Bundle.main

        // Bundled assets.
        guard let esptoolBundled = bundle.url(forResource: "esptool", withExtension: nil),
              let bootloader    = bundle.url(forResource: "firmware-bootloader", withExtension: "bin"),
              let partitions    = bundle.url(forResource: "firmware-partitions", withExtension: "bin"),
              let bootApp0      = bundle.url(forResource: "firmware-boot_app0", withExtension: "bin"),
              let app           = bundle.url(forResource: "firmware-app", withExtension: "bin")
        else {
            throw NSError(domain: "FirmwareFlasher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled firmware assets are missing from the app."])
        }

        // Copy esptool to a temp dir and chmod +x so we can run it. Bundle
        // executables don't always retain the exec bit through codesigning, and
        // the temp copy decouples lifetime from the running app.
        let tempDir = fm.temporaryDirectory.appendingPathComponent("CaptureKVM-flasher", isDirectory: true)
        try? fm.removeItem(at: tempDir)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let esptool = tempDir.appendingPathComponent("esptool")
        try fm.copyItem(at: esptoolBundled, to: esptool)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: esptool.path)

        // Build the command.
        let proc = Process()
        proc.executableURL = esptool
        proc.arguments = [
            "--chip", "esp32s3",
            "--port", port,
            "--baud", "460800",
            "--before", "default_reset",
            "--after", "hard_reset",
            "write_flash",
            "-z",
            "--flash_mode", "qio",
            "--flash_freq", "80m",
            "--flash_size", "8MB",
            "0x0",     bootloader.path,
            "0x8000",  partitions.path,
            "0xe000",  bootApp0.path,
            "0x10000", app.path,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(text) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(text) }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                if p.terminationStatus == 0 {
                    flashLog.info("esptool exited cleanly, starting post-flash verify")
                    self.progressPercent = 100
                    self.lastLogLine = "Flashed. Verifying device responds…"
                    self.isVerifying = true
                    // Give the chip a moment to reset and bring up the firmware.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.runVerify()
                    }
                } else {
                    self.isFlashing = false
                    let msg = "esptool exited with status \(p.terminationStatus). See log."
                    self.lastError = msg
                    flashLog.error("\(msg, privacy: .public)")
                }
            }
        }

        flashLog.info("launching esptool against port \(port, privacy: .public)")
        try proc.run()
        process = proc
    }

    /// Parse a chunk of esptool output for progress markers and the latest log line.
    private func ingest(_ text: String) {
        stdoutBuffer.append(text)
        // Split on \r and \n; esptool uses \r for in-place progress updates.
        let separators: Set<Character> = ["\n", "\r"]
        var line = ""
        for ch in text {
            if separators.contains(ch) {
                if !line.isEmpty {
                    handleLine(line)
                    line = ""
                }
            } else {
                line.append(ch)
            }
        }
        if !line.isEmpty { handleLine(line) }
    }

    private static let percentRegex = try! NSRegularExpression(pattern: "(\\d{1,3})\\s*%", options: [])

    // MARK: - Post-flash verification
    //
    // esptool reporting "Hash of data verified" only means the bytes landed in
    // flash; it doesn't tell us whether the device boots. Boot-loop conditions
    // (e.g. flash-mode mismatch with the chip) still look like a successful
    // flash. So after esptool finishes we open the same port, send a ping
    // frame, and wait for the firmware's 0xAA pong byte. If that arrives, the
    // chip really is running our firmware. If it times out, we surface that
    // clearly instead of falsely claiming success.

    private func runVerify() {
        let ok = probeBootedFirmware(port: portInUse, perBaudTimeoutMs: 250)
        isFlashing = false
        isVerifying = false
        if ok {
            lastSuccess = true
            lastLogLine = "Verified: ESP32 responded to a ping. Firmware is running."
            flashLog.info("post-flash verify succeeded")
        } else {
            lastError = "Flash completed, but the device didn't respond to a ping afterwards. This usually means it's in a boot loop — most often a flash-mode mismatch with the chip on the board. Check the UART boot output, or try a different bundled firmware build."
            flashLog.error("post-flash verify failed on \(self.portInUse, privacy: .public)")
        }
    }

    private func probeBootedFirmware(port: String, perBaudTimeoutMs: Int) -> Bool {
        let fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            flashLog.error("verify: open(\(port, privacy: .public)) failed errno=\(errno)")
            return false
        }
        defer { close(fd) }

        var tio = termios()
        guard tcgetattr(fd, &tio) == 0 else { return false }
        cfmakeraw(&tio)
        tio.c_cflag |= (tcflag_t(CLOCAL) | tcflag_t(CREAD))
        tio.c_cflag &= ~tcflag_t(CRTSCTS)

        let pingFrame = HIDEncoder.frame(type: 0x80, payload: [])

        // Match the bauds ESP32Serial.connect() probes, high to low.
        for baud in [921600, 460800, 230400, 115200] {
            cfsetispeed(&tio, speed_t(baud))
            cfsetospeed(&tio, speed_t(baud))
            guard tcsetattr(fd, TCSANOW, &tio) == 0 else { continue }
            tcflush(fd, TCIOFLUSH)

            pingFrame.withUnsafeBytes { buf in
                _ = Darwin.write(fd, buf.baseAddress, buf.count)
            }

            let deadline = Date().addingTimeInterval(TimeInterval(perBaudTimeoutMs) / 1000.0)
            var byte: UInt8 = 0
            while Date() < deadline {
                let n = Darwin.read(fd, &byte, 1)
                if n == 1 && byte == 0xAA { return true }
                if n < 0 && errno != EAGAIN { break }
                usleep(2000)
            }
        }
        return false
    }

    private func handleLine(_ line: String) {
        lastLogLine = line
        // Pull the largest % value we see; esptool reports both per-region
        // progress and overall progress in different builds.
        let range = NSRange(line.startIndex..., in: line)
        if let match = FirmwareFlasher.percentRegex.firstMatch(in: line, options: [], range: range),
           let r = Range(match.range(at: 1), in: line),
           let pct = Int(line[r]) {
            progressPercent = max(progressPercent, min(100, pct))
        }
    }
}
