#if os(iOS)
import AVFoundation
import CoreImage.CIFilterBuiltins
import SpeakCore
import SwiftUI

// MARK: - QR Code Generator View

/// Displays a QR code containing settings for transfer to another device.
struct QRCodeGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?
    @State private var isGenerating = false
    @State private var error: String?
    @State private var settingCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isGenerating {
                    ProgressView("Generating...")
                        .padding()
                } else if let image = qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 250, maxHeight: 250)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

                    Text("Scan this code on your other device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("This QR code transfers settings only. API keys are not included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Label("\(settingCount) settings", systemImage: "gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Enter API keys manually, or sync them through iCloud Keychain.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)

                    Text("Code expires in 10 minutes")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if let error {
                    ContentUnavailableView {
                        Label("Generation Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            Task { await generateQRCode() }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Configuration", systemImage: "qrcode")
                    } description: {
                        Text("No supported settings to transfer")
                    }
                }
            }
            .padding()
            .navigationTitle("Share Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await generateQRCode() }
        }
    }

    private func generateQRCode() async {
        isGenerating = true
        error = nil

        do {
            let settings = gatherSettings()
            settingCount = settings.count

            guard !settings.isEmpty else {
                qrImage = nil
                isGenerating = false
                return
            }

            let payload = try ConfigTransferManager.shared.generatePayload(settings: settings)

            // Generate QR code image
            let context = CIContext()
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(payload.utf8)
            filter.correctionLevel = "M"

            guard let outputImage = filter.outputImage else {
                throw ConfigTransferError.decodingFailed
            }

            // Scale up for display
            let scale = 10.0
            let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                qrImage = UIImage(cgImage: cgImage)
            }
        } catch {
            self.error = error.localizedDescription
        }

        isGenerating = false
    }

    private func gatherSettings() -> [String: String] {
        var settings: [String: String] = [:]

        let model = AppSettings.shared.selectedModel
        if !model.isEmpty {
            settings["selectedModel"] = model
        }

        return settings
    }
}

// MARK: - QR Code Scanner View

/// Scans a QR code to import configuration from another device.
struct QRCodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = QRScannerCoordinator()
    @State private var showingImportConfirmation = false
    @State private var pendingPayload: ConfigTransferPayload?
    @State private var importError: String?
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Camera preview
                CameraPreviewView(session: scanner.session)
                    .ignoresSafeArea()

                // Overlay
                VStack {
                    Spacer()

                    // Scanning indicator
                    if scanner.isScanning {
                        Text("Point camera at QR code")
                            .font(.headline)
                            .padding()
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer()

                    // Frame guide
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 2)
                        .frame(width: 250, height: 250)

                    Spacer()
                    Spacer()
                }
            }
            .navigationTitle("Scan Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { scanner.startScanning() }
            .onDisappear { scanner.stopScanning() }
            .onChange(of: scanner.scannedCode) { _, code in
                if let code {
                    handleScannedCode(code)
                }
            }
            .alert("Import Configuration?", isPresented: $showingImportConfirmation) {
                Button("Import") {
                    Task { await importPayload() }
                }
                Button("Cancel", role: .cancel) {
                    pendingPayload = nil
                    scanner.startScanning()
                }
            } message: {
                if let payload = pendingPayload {
                    Text(
                        "Import \(payload.settings.count) settings? "
                            + "API keys are not included in QR transfers."
                    )
                }
            }
            .alert("Import Error", isPresented: .init(
                get: { importError != nil },
                set: { if !$0 { importError = nil; scanner.startScanning() } }
            )) {
                Button("OK") {}
            } message: {
                if let error = importError {
                    Text(error)
                }
            }
            .overlay {
                if isImporting {
                    ProgressView("Importing...")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func handleScannedCode(_ code: String) {
        scanner.stopScanning()

        do {
            let payload = try ConfigTransferManager.shared.decodePayload(code)

            guard ConfigTransferManager.shared.validatePayloadFreshness(payload) else {
                throw ConfigTransferError.payloadExpired
            }

            pendingPayload = payload
            showingImportConfirmation = true
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importPayload() async {
        guard let payload = pendingPayload else { return }

        isImporting = true

        do {
            for (key, value) in payload.settings {
                switch key {
                case "selectedModel":
                    AppSettings.shared.selectedModel = value
                default:
                    throw ConfigTransferError.unsupportedSettings([key])
                }
            }

            isImporting = false
            dismiss()
        } catch {
            isImporting = false
            importError = error.localizedDescription
        }
    }
}

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
