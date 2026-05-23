import Foundation
import Network
import CryptoKit
import AVFoundation
import CoreMedia
import VideoToolbox

final class RemoteUDPVideoSource {
    struct Configuration {
        let host: String
        let port: UInt16
        let sessionID: UInt64
        let sessionKey: Data
    }

    private enum Constants {
        static let magic = Data([0x43, 0x4B, 0x56, 0x4D])
        static let protocolVersion: UInt8 = 1
        static let directionServerToClient: UInt8 = 0x02
        static let directionClientToServer: UInt8 = 0x01
        static let headerBytes = 30
        static let gcmTagBytes = 16
        static let packetKindVideoConfig: UInt8 = 0x10
        static let packetKindVideoFrame: UInt8 = 0x11
        static let packetKindVideoPing: UInt8 = 0x12
        static let frameFragmentHeaderBytes = 12
        static let keyframeFlag: UInt16 = 1 << 0
    }

    private let queue = DispatchQueue(label: "CaptureKVM.remote.video", qos: .userInteractive)
    private let displayLayer: AVSampleBufferDisplayLayer

    private var connection: NWConnection?
    private var configuration: Configuration?
    private var replayWindow = ReplayWindow()
    private var frameReassembler = FrameReassembler(maxFrames: 3)
    private var formatDescription: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var negotiatedFPS: Int = 60
    private var sequence: UInt32 = 0

    private(set) var isConnected: Bool = false
    private(set) var isReceiving: Bool = false

    var onConnectionChanged: ((Bool) -> Void)?
    var onReceivingChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    var statusDescription: String {
        if isReceiving { return "Remote video receiving" }
        if isConnected { return "Remote video waiting" }
        return "Remote video disconnected"
    }

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
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
                    self.receiveNextMessage()
                    self.sendPing()
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                case .failed(let error):
                    self.handleDisconnect()
                    self.onError?("Remote video failed: \(error.localizedDescription)")
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    self.handleDisconnect()
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
        handleDisconnect()
    }

    private func handleDisconnect() {
        replayWindow = ReplayWindow()
        frameReassembler = FrameReassembler(maxFrames: 3)
        formatDescription = nil
        sps = nil
        pps = nil
        sequence = 0
        negotiatedFPS = 60
        if isConnected {
            isConnected = false
            onConnectionChanged?(false)
        }
        if isReceiving {
            isReceiving = false
            onReceivingChanged?(false)
        }
        DispatchQueue.main.async { [displayLayer] in
            displayLayer.sampleBufferRenderer.flush()
        }
    }

    private func receiveNextMessage() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.onError?("Remote video receive failed: \(error.localizedDescription)")
                return
            }
            if let data, !data.isEmpty {
                self.handleDatagram(data)
            }
            if self.connection != nil {
                self.receiveNextMessage()
            }
        }
    }

    private func sendPing() {
        guard let configuration, let connection else { return }
        do {
            sequence &+= 1
            let header = makeHeader(
                kind: Constants.packetKindVideoPing,
                flags: 0,
                sessionID: configuration.sessionID,
                sequence: sequence,
                timestampUS: UInt64(Date().timeIntervalSince1970 * 1_000_000),
                payloadLength: 0
            )
            let sealed = try AES.GCM.seal(
                Data(),
                using: SymmetricKey(data: configuration.sessionKey),
                nonce: try AES.GCM.Nonce(data: makeNonce(sessionID: configuration.sessionID, direction: Constants.directionClientToServer, sequence: sequence)),
                authenticating: header
            )
            var packet = header
            packet.append(sealed.ciphertext)
            packet.append(sealed.tag)
            connection.send(content: packet, completion: .contentProcessed({ [weak self] error in
                if let error {
                    self?.onError?("Remote video ping failed: \(error.localizedDescription)")
                }
            }))
        } catch {
            onError?("Remote video ping crypto failed: \(error.localizedDescription)")
        }
    }

    private func handleDatagram(_ datagram: Data) {
        guard let configuration else { return }
        do {
            let header = try parseHeader(datagram)
            let payload = try openPayload(datagram: datagram, header: header, configuration: configuration)
            guard replayWindow.accept(sequence: header.sequence) else { return }
            switch header.kind {
            case Constants.packetKindVideoConfig:
                applyVideoConfig(payload)
            case Constants.packetKindVideoFrame:
                try handleVideoFrame(payload: payload, header: header)
            default:
                break
            }
        } catch {
            onError?("Remote video packet rejected: \(error.localizedDescription)")
        }
    }

    private func openPayload(datagram: Data, header: PacketHeader, configuration: Configuration) throws -> Data {
        guard header.sessionID == configuration.sessionID else {
            throw RemoteControlAPIError.invalidResponse
        }
        guard datagram.count == Constants.headerBytes + Int(header.payloadLength) + Constants.gcmTagBytes else {
            throw RemoteControlAPIError.invalidResponse
        }
        let ciphertextRange = Constants.headerBytes..<datagram.count
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: makeNonce(sessionID: configuration.sessionID, direction: Constants.directionServerToClient, sequence: header.sequence)),
            ciphertext: Data(datagram[ciphertextRange].dropLast(Constants.gcmTagBytes)),
            tag: Data(datagram[ciphertextRange].suffix(Constants.gcmTagBytes))
        )
        let plaintext = try AES.GCM.open(
            sealedBox,
            using: SymmetricKey(data: configuration.sessionKey),
            authenticating: datagram.prefix(Constants.headerBytes)
        )
        guard plaintext.count == Int(header.payloadLength) else {
            throw RemoteControlAPIError.invalidResponse
        }
        return plaintext
    }

    private func applyVideoConfig(_ payload: Data) {
        guard payload.count >= 8 else { return }
        negotiatedFPS = max(1, Int(payload.readUInt16(at: 6)))
    }

    private func handleVideoFrame(payload: Data, header: PacketHeader) throws {
        guard payload.count >= Constants.frameFragmentHeaderBytes else {
            throw RemoteControlAPIError.invalidResponse
        }

        let fragment = FrameFragment(
            frameID: payload.readUInt32(at: 0),
            totalBytes: Int(payload.readUInt32(at: 4)),
            index: Int(payload.readUInt16(at: 8)),
            count: Int(payload.readUInt16(at: 10)),
            data: payload.dropFirst(Constants.frameFragmentHeaderBytes),
            timestampUS: header.timestampUS,
            keyframe: (header.flags & Constants.keyframeFlag) != 0
        )

        guard let frame = frameReassembler.ingest(fragment: fragment) else { return }
        try enqueue(frame: frame)
        if !isReceiving {
            isReceiving = true
            onReceivingChanged?(true)
        }
    }

    private func enqueue(frame: ReassembledFrame) throws {
        let nalUnits = extractNALUnits(from: frame.data)
        guard !nalUnits.isEmpty else { return }

        var sampleNALs: [Data] = []
        var formatNeedsRefresh = formatDescription == nil
        for unit in nalUnits {
            guard let type = unit.first.map({ $0 & 0x1F }) else { continue }
            switch type {
            case 7:
                if sps != unit {
                    sps = unit
                    formatNeedsRefresh = true
                }
            case 8:
                if pps != unit {
                    pps = unit
                    formatNeedsRefresh = true
                }
            case 9:
                continue
            default:
                sampleNALs.append(unit)
            }
        }

        guard let sps, let pps else { return }
        if formatNeedsRefresh {
            formatDescription = try makeFormatDescription(sps: sps, pps: pps)
            DispatchQueue.main.async { [displayLayer] in
                displayLayer.sampleBufferRenderer.flush()
            }
        }
        guard let formatDescription, !sampleNALs.isEmpty else { return }

        var sampleData = Data()
        for nal in sampleNALs {
            sampleData.append(contentsOf: bigEndianBytes(UInt32(nal.count)))
            sampleData.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw RemoteControlAPIError.invalidResponse
        }

        sampleData.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: sampleData.count)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(max(1, negotiatedFPS))),
            presentationTimeStamp: CMTime(value: CMTimeValue(frame.timestampUS), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RemoteControlAPIError.invalidResponse
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
            let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            CFDictionarySetValue(attachment, key, value)
        }

        DispatchQueue.main.async { [displayLayer] in
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        }
    }

    private func makeFormatDescription(sps: Data, pps: Data) throws -> CMFormatDescription {
        var formatDescription: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                var parameterSetPointers: [UnsafePointer<UInt8>?] = [
                    spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                ]
                let parameterSetSizes = [sps.count, pps.count]
                return parameterSetPointers.withUnsafeMutableBufferPointer { pointerBuffer in
                    parameterSetSizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            }
        }
        guard status == noErr, let formatDescription else {
            throw RemoteControlAPIError.invalidResponse
        }
        return formatDescription
    }

    private func parseHeader(_ datagram: Data) throws -> PacketHeader {
        guard datagram.count >= Constants.headerBytes + Constants.gcmTagBytes else {
            throw RemoteControlAPIError.invalidResponse
        }
        guard datagram.prefix(4) == Constants.magic else {
            throw RemoteControlAPIError.invalidResponse
        }
        guard datagram[4] == Constants.protocolVersion else {
            throw RemoteControlAPIError.invalidResponse
        }
        return PacketHeader(
            kind: datagram[5],
            flags: datagram.readUInt16(at: 6),
            sessionID: datagram.readUInt64(at: 8),
            sequence: datagram.readUInt32(at: 16),
            timestampUS: datagram.readUInt64(at: 20),
            payloadLength: datagram.readUInt16(at: 28)
        )
    }

    private func makeHeader(kind: UInt8, flags: UInt16, sessionID: UInt64, sequence: UInt32, timestampUS: UInt64, payloadLength: Int) -> Data {
        var data = Data()
        data.append(Constants.magic)
        data.append(Constants.protocolVersion)
        data.append(kind)
        data.append(contentsOf: bigEndianBytes(flags))
        data.append(contentsOf: bigEndianBytes(sessionID))
        data.append(contentsOf: bigEndianBytes(sequence))
        data.append(contentsOf: bigEndianBytes(timestampUS))
        data.append(contentsOf: bigEndianBytes(UInt16(payloadLength)))
        return data
    }

    private func makeNonce(sessionID: UInt64, direction: UInt8, sequence: UInt32) -> Data {
        let sessionBytes = bigEndianBytes(sessionID)
        var nonce = Data()
        nonce.append(contentsOf: sessionBytes.dropFirst())
        nonce.append(direction)
        nonce.append(contentsOf: bigEndianBytes(sequence))
        return nonce
    }

    private func extractNALUnits(from annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var starts: [(Int, Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else if index + 4 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else {
                index += 1
            }
        }

        guard !starts.isEmpty else { return [] }
        var units: [Data] = []
        for (offset, markerLength) in starts.enumerated() {
            let start = markerLength.0 + markerLength.1
            let end = offset + 1 < starts.count ? starts[offset + 1].0 : bytes.count
            guard start < end else { continue }
            units.append(Data(bytes[start..<end]))
        }
        return units
    }

    private func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}

private struct PacketHeader {
    let kind: UInt8
    let flags: UInt16
    let sessionID: UInt64
    let sequence: UInt32
    let timestampUS: UInt64
    let payloadLength: UInt16
}

private struct FrameFragment {
    let frameID: UInt32
    let totalBytes: Int
    let index: Int
    let count: Int
    let data: Data.SubSequence
    let timestampUS: UInt64
    let keyframe: Bool
}

private struct ReassembledFrame {
    let data: Data
    let timestampUS: UInt64
    let keyframe: Bool
}

private struct ReplayWindow {
    private var initialized = false
    private var highest: UInt32 = 0
    private var seen: UInt64 = 0

    mutating func accept(sequence: UInt32) -> Bool {
        if !initialized {
            initialized = true
            highest = sequence
            seen = 1
            return true
        }
        if sequence > highest {
            let shift = sequence - highest
            if shift >= 64 {
                seen = 0
            } else {
                seen <<= shift
            }
            highest = sequence
            seen |= 1
            return true
        }
        let distance = highest - sequence
        if distance >= 64 { return false }
        let mask = UInt64(1) << distance
        if seen & mask != 0 { return false }
        seen |= mask
        return true
    }
}

private struct FrameReassembler {
    private struct PendingFrame {
        let totalBytes: Int
        let timestampUS: UInt64
        let keyframe: Bool
        var fragments: [Int: Data]
        let expectedFragments: Int
    }

    private let maxFrames: Int
    private var frames: [UInt32: PendingFrame] = [:]
    private var order: [UInt32] = []

    init(maxFrames: Int) {
        self.maxFrames = maxFrames
    }

    mutating func ingest(fragment: FrameFragment) -> ReassembledFrame? {
        guard fragment.count > 0,
              fragment.index >= 0,
              fragment.index < fragment.count,
              fragment.totalBytes > 0 else { return nil }

        if frames[fragment.frameID] == nil {
            if order.count >= maxFrames, let oldest = order.first {
                frames.removeValue(forKey: oldest)
                order.removeFirst()
            }
            frames[fragment.frameID] = PendingFrame(
                totalBytes: fragment.totalBytes,
                timestampUS: fragment.timestampUS,
                keyframe: fragment.keyframe,
                fragments: [:],
                expectedFragments: fragment.count
            )
            order.append(fragment.frameID)
        }

        guard var pending = frames[fragment.frameID],
              pending.totalBytes == fragment.totalBytes,
              pending.expectedFragments == fragment.count else {
            frames.removeValue(forKey: fragment.frameID)
            order.removeAll { $0 == fragment.frameID }
            return nil
        }

        pending.fragments[fragment.index] = Data(fragment.data)
        frames[fragment.frameID] = pending

        guard pending.fragments.count == pending.expectedFragments else { return nil }
        var assembled = Data()
        for index in 0..<pending.expectedFragments {
            guard let piece = pending.fragments[index] else { return nil }
            assembled.append(piece)
        }
        guard assembled.count == pending.totalBytes else { return nil }

        frames.removeValue(forKey: fragment.frameID)
        order.removeAll { $0 == fragment.frameID }
        return ReassembledFrame(data: assembled, timestampUS: pending.timestampUS, keyframe: pending.keyframe)
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    func readUInt64(at offset: Int) -> UInt64 {
        subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }
}
