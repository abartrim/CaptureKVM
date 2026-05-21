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

    var isRunning: Bool { session.isRunning }

    func enumerateVideoDevices() -> [CaptureDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        return discovery.devices.map { CaptureDeviceInfo(uniqueID: $0.uniqueID, localizedName: $0.localizedName) }
    }

    func start(device: CaptureDeviceInfo) {
        session.beginConfiguration()
        if let input = input { session.removeInput(input); self.input = nil }
        if let avDevice = AVCaptureDevice(uniqueID: device.uniqueID) {
            do {
                let newInput = try AVCaptureDeviceInput(device: avDevice)
                if session.canAddInput(newInput) { session.addInput(newInput); input = newInput }
            } catch {
                print("Capture input error: \(error)")
            }
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
    }
}

struct CapturePreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}
