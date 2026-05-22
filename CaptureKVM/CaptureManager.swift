import AVFoundation
import SwiftUI
import AppKit

struct CaptureDeviceInfo: Identifiable {
    let uniqueID: String
    let localizedName: String
    var id: String { uniqueID }
}

final class CaptureManager {
    let session = AVCaptureSession()
    private var input: AVCaptureDeviceInput?

    // Direct-render path: data output + sample-buffer display layer.
    // Avoids the extra buffering Core Animation does behind AVCaptureVideoPreviewLayer.
    let displayLayer = AVSampleBufferDisplayLayer()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let outputQueue = DispatchQueue(label: "CaptureKVM.video.output", qos: .userInteractive)
    private let outputDelegate: VideoOutputDelegate

    var isRunning: Bool { session.isRunning }

    init() {
        outputDelegate = VideoOutputDelegate(displayLayer: displayLayer)
        displayLayer.videoGravity = .resizeAspect
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(outputDelegate, queue: outputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
    }

    func enumerateVideoDevices() -> [CaptureDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        return discovery.devices.map { CaptureDeviceInfo(uniqueID: $0.uniqueID, localizedName: $0.localizedName) }
    }

    func start(device: CaptureDeviceInfo) {
        session.beginConfiguration()
        if let input = input { session.removeInput(input); self.input = nil }
        let avDevice = AVCaptureDevice(uniqueID: device.uniqueID)
        if let avDevice {
            do {
                let newInput = try AVCaptureDeviceInput(device: avDevice)
                if session.canAddInput(newInput) { session.addInput(newInput); input = newInput }
            } catch {
                print("Capture input error: \(error)")
            }
        }
        session.commitConfiguration()
        if let avDevice { configureHighestFrameRate(on: avDevice) }
        if !session.isRunning { session.startRunning() }
    }

    /// Pick the highest-FPS format the device supports. Tiebreak on largest resolution.
    /// Pinning both min and max frame duration locks the device at that rate.
    private func configureHighestFrameRate(on device: AVCaptureDevice) {
        var bestFormat: AVCaptureDevice.Format?
        var bestRange: AVFrameRateRange?

        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if let cur = bestRange {
                    if range.maxFrameRate > cur.maxFrameRate {
                        bestFormat = format; bestRange = range
                    } else if range.maxFrameRate == cur.maxFrameRate, let curBest = bestFormat {
                        let new = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let cur = CMVideoFormatDescriptionGetDimensions(curBest.formatDescription)
                        if Int(new.width) * Int(new.height) > Int(cur.width) * Int(cur.height) {
                            bestFormat = format; bestRange = range
                        }
                    }
                } else {
                    bestFormat = format; bestRange = range
                }
            }
        }

        guard let format = bestFormat, let range = bestRange else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
            device.unlockForConfiguration()
        } catch {
            print("Couldn't lock device for high-FPS config: \(error)")
        }
    }
}

/// Forwards each captured frame straight to the display layer.
/// `alwaysDiscardsLateVideoFrames` on the output guarantees we only see the freshest frame.
final class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // nonisolated(unsafe) so we can read it from the (nonisolated) delegate callback on
    // the userInteractive output queue without bouncing back to the main actor.
    // AVSampleBufferDisplayLayer isn't formally Sendable but its sampleBufferRenderer
    // enqueue path is documented thread-safe, so this is safe in practice.
    nonisolated(unsafe) let displayLayer: AVSampleBufferDisplayLayer
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // sampleBufferRenderer.enqueue is the macOS 15+ entry point; the deprecated
        // AVSampleBufferDisplayLayer.enqueue was just a shim over this. Thread-safe.
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
    }
}

struct CapturePreviewView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = displayLayer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.layer !== displayLayer {
            nsView.layer = displayLayer
        }
    }
}
