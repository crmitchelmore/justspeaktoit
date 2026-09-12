#if os(iOS)
import CoreImage.CIFilterBuiltins
import SpeakCore
import SwiftUI

// MARK: - QR Code Generator View

/// Displays a QR code containing encrypted configuration for transfer to another device.
struct QRCodeGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?
    @State private var presentation: ConfigTransferPresentation?
    @State private var isGenerating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isGenerating {
                    ProgressView("Generating...")
                        .padding()
                } else if let image = qrImage {
                    if presentation?.isShowingQRCode == true {
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
                        Button(ConfigTransferPresentation.revealButtonTitle) {
                            presentation?.revealCode()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let transferCode = presentation?.visibleCode {
                        VStack(spacing: 6) {
                            Text("Enter this code on the receiving device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ConfigTransferCode.formatted(transferCode))
                                .font(.system(.title, design: .monospaced))
                                .fontWeight(.semibold)
                                .textSelection(.enabled)
                                .accessibilityLabel(
                                    Text(transferCode.map { String($0) }.joined(separator: " "))
                                )
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }

                    Text(ConfigTransferPresentation.captureNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ConfigTransferPresentation.expiryNotice)
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
                        Text("No API keys or settings to transfer")
                    }
                }
            }
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .padding()
            .navigationTitle("Share Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Same escape hatch as macOS: a failed scan after the code
                    // was revealed starts a fresh transfer instead of forcing
                    // the user to leave the screen.
                    if qrImage != nil, !isGenerating {
                        Button("Regenerate") {
                            Task { await generateQRCode() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await generateQRCode() }
        }
    }

    private func generateQRCode() async {
        guard !isGenerating else { return }
        isGenerating = true
        error = nil
        qrImage = nil
        presentation = nil

        do {
            // Gather secrets and settings via the shared transfer manager so
            // both platforms use the same key list and payload format. Read from
            // the canonical credential store the rest of the app uses.
            let manager = ConfigTransferManager.shared
            let secrets = try await manager.gatherSecrets(storage: AppSettings.canonicalCredentialStorage)
            try Task.checkCancellation()
            let settings = manager.gatherSettings()

            guard !secrets.isEmpty || !settings.isEmpty else {
                qrImage = nil
                presentation = nil
                isGenerating = false
                return
            }

            // A fresh transfer resets the one-way presentation flow. The QR
            // must leave the view before the unlock code can be shown.
            let transfer = try manager.makeTransfer(
                secrets: secrets,
                settings: settings
            )

            guard let scaledImage = manager.makeQRCodeImage(payload: transfer.payload) else {
                throw ConfigTransferError.qrGenerationFailed
            }

            let context = CIContext()
            guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
                throw ConfigTransferError.qrGenerationFailed
            }
            qrImage = UIImage(cgImage: cgImage)
            presentation = ConfigTransferPresentation(code: transfer.code)
        } catch {
            qrImage = nil
            presentation = nil
            self.error = error.localizedDescription
        }

        isGenerating = false
    }
}

// MARK: - QR Code Scanner View

/// Scans a QR code to import configuration from another device.
struct QRCodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = QRScannerCoordinator()
    @State private var showingImportConfirmation = false
    @State private var showingCodePrompt = false
    /// The scanned ciphertext, held until the user types the code that unlocks it.
    @State private var scannedEnvelope: String?
    @State private var enteredCode = ""
    /// Whether the last failure was a bad code, i.e. worth re-prompting instead
    /// of sending the user back to the camera.
    @State private var canRetryCode = false
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
            .alert("Enter Transfer Code", isPresented: $showingCodePrompt) {
                TextField("\(ConfigTransferCode.length)-character code", text: $enteredCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Unlock") { unlockScannedPayload() }
                Button("Cancel", role: .cancel) { cancelPendingImport() }
            } message: {
                Text(ConfigTransferPresentation.receiverInstruction)
            }
            .alert("Import Configuration?", isPresented: $showingImportConfirmation) {
                Button("Import") {
                    Task { await importPayload() }
                }
                Button("Cancel", role: .cancel) { cancelPendingImport() }
            } message: {
                if let payload = pendingPayload {
                    Text("Import \(payload.secrets.count) API keys and \(payload.settings.count) settings?")
                }
            }
            .alert("Import Error", isPresented: .init(
                get: { importError != nil },
                set: { if !$0 { dismissImportError() } }
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

    /// Nothing is decrypted at scan time: an encrypted payload is parked until
    /// the user supplies the one-time code from the exporting device.
    private func handleScannedCode(_ code: String) {
        scanner.stopScanning()

        do {
            switch try ConfigTransferManager.shared.format(of: code) {
            case .encrypted:
                scannedEnvelope = code
                enteredCode = ""
                showingCodePrompt = true
            case .legacy:
                let payload = try ConfigTransferManager.shared.decodeLegacyPayload(code)
                guard ConfigTransferManager.shared.validatePayloadFreshness(payload) else {
                    throw ConfigTransferError.payloadExpired
                }
                pendingPayload = payload
                showingImportConfirmation = true
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Decrypts the parked payload with the typed code. A wrong code, an expired
    /// code or a tampered payload all fail here, before any credential is stored.
    private func unlockScannedPayload() {
        guard let envelope = scannedEnvelope else { return }

        do {
            pendingPayload = try ConfigTransferManager.shared.decodePayload(envelope, code: enteredCode)
            enteredCode = ""
            showingImportConfirmation = true
        } catch {
            enteredCode = ""
            // A mistyped code shouldn't cost the user another scan: keep the
            // payload and re-prompt once the error is acknowledged. Anything
            // else (expired, unknown version, corrupt) needs a fresh code.
            let transferError = error as? ConfigTransferError
            canRetryCode = transferError == .authenticationFailed || transferError == .invalidCode
            importError = error.localizedDescription
        }
    }

    private func dismissImportError() {
        importError = nil
        guard canRetryCode, scannedEnvelope != nil else {
            cancelPendingImport()
            return
        }
        canRetryCode = false
        // Re-present on the next runloop pass so SwiftUI has finished
        // dismissing the error alert before the code prompt appears.
        Task { @MainActor in showingCodePrompt = true }
    }

    private func cancelPendingImport() {
        pendingPayload = nil
        scannedEnvelope = nil
        enteredCode = ""
        canRetryCode = false
        scanner.startScanning()
    }

    private func importPayload() async {
        guard let payload = pendingPayload else { return }

        isImporting = true

        do {
            // Write to the canonical credential store the rest of the app reads,
            // so imported keys are actually visible in Settings. The shared
            // manager applies the payload transactionally: a failed write
            // rolls every already-applied credential back (issue #699).
            try await ConfigTransferManager.shared.applyImport(
                payload: payload,
                storage: AppSettings.canonicalCredentialStorage
            )

            pendingPayload = nil
            scannedEnvelope = nil
            isImporting = false
            dismiss()
        } catch {
            isImporting = false
            importError = error.localizedDescription
        }
    }
}

#endif
