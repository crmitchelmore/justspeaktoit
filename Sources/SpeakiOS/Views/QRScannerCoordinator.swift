#if os(iOS)
import AVFoundation
import SwiftUI

// Camera plumbing for the QR config-transfer scanner, split out of
// ConfigTransferView so the transfer UI and the capture session stay separate.

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - QR Scanner Coordinator

@MainActor
class QRScannerCoordinator: NSObject, ObservableObject {
    @Published var scannedCode: String?
    @Published var isScanning = false

    let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()

    override init() {
        super.init()
        setupSession()
    }

    private func setupSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = [.qr]
        }
    }

    func startScanning() {
        scannedCode = nil
        isScanning = true
        Task.detached { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopScanning() {
        isScanning = false
        Task.detached { [weak self] in
            self?.session.stopRunning()
        }
    }
}

extension QRScannerCoordinator: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let stringValue = metadataObject.stringValue
        else { return }

        Task { @MainActor in
            scannedCode = stringValue
        }
    }
}
#endif
