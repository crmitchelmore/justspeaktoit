#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import SpeakCore
import SwiftUI

// MARK: - QR Code Generator View for macOS

/// Displays a QR code containing encrypted configuration for transfer to iOS device.
struct ConfigTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: NSImage?
    @State private var presentation: ConfigTransferPresentation?
    @State private var isGenerating = false
    @State private var error: String?
    @State private var secretCount = 0
    @State private var settingCount = 0

    private let secureStorage: SecureAppStorage

    init(secureStorage: SecureAppStorage) {
        self.secureStorage = secureStorage
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text("Transfer to iOS")
                .font(.headline)

            if isGenerating {
                ProgressView("Generating QR Code…")
                    .padding()
            } else if let image = qrImage {
                VStack(spacing: 16) {
                    if presentation?.isShowingQRCode == true {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .background(Color.white)
                            .cornerRadius(8)

                        Text("Scan with Just Speak to It on iOS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(ConfigTransferPresentation.revealButtonTitle) {
                            presentation?.revealCode()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let transferCode = presentation?.visibleCode {
                        VStack(spacing: 4) {
                            Text("Enter this code on the receiving device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ConfigTransferCode.formatted(transferCode))
                                .font(.system(.title2, design: .monospaced))
                                .fontWeight(.semibold)
                                .textSelection(.enabled)
                                .accessibilityLabel(
                                    Text(transferCode.map { String($0) }.joined(separator: " "))
                                )
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    HStack(spacing: 16) {
                        Label("\(secretCount) API keys", systemImage: "key.fill")
                        Label("\(settingCount) settings", systemImage: "gearshape")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(ConfigTransferPresentation.captureNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ConfigTransferPresentation.expiryNotice)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Generation Failed")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await generateQRCode() }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "qrcode")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Configuration")
                        .font(.headline)
                    Text("No API keys or settings to transfer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                if qrImage != nil {
                    Button("Regenerate") {
                        Task { await generateQRCode() }
                    }
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .padding(24)
        .frame(width: 300)
        .task { await generateQRCode() }
    }

    private func generateQRCode() async {
        isGenerating = true
        error = nil
        qrImage = nil
        presentation = nil

        do {
            // Gather secrets and settings via the shared transfer manager so
            // both platforms use the same key list and payload format.
            let manager = ConfigTransferManager.shared
            let secrets = try await manager.gatherSecrets(storage: secureStorage.coreStorage())
            let settings = manager.gatherSettings(liveModelDefaultsKey: "liveTranscriptionModel")

            secretCount = secrets.count
            settingCount = settings.count

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

            let rep = NSCIImageRep(ciImage: scaledImage)
            let nsImage = NSImage(size: rep.size)
            nsImage.addRepresentation(rep)
            qrImage = nsImage
            presentation = ConfigTransferPresentation(code: transfer.code)
        } catch {
            qrImage = nil
            presentation = nil
            self.error = error.localizedDescription
        }

        isGenerating = false
    }
}

// Preview requires AppEnvironment - use in Xcode with proper setup
// #Preview {
//     ConfigTransferView(secureStorage: ...)
// }
#endif
