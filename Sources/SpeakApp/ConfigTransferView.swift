#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import SpeakCore
import SwiftUI

// MARK: - QR Code Generator View for macOS

/// Displays a QR code containing settings for transfer to iOS.
struct ConfigTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettings
    @State private var qrImage: NSImage?
    @State private var isGenerating = false
    @State private var error: String?
    @State private var settingCount = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("Transfer to iOS")
                .font(.headline)

            if isGenerating {
                ProgressView("Generating QR Code...")
                    .padding()
            } else if let image = qrImage {
                VStack(spacing: 16) {
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

                    Text("This QR code transfers settings only. API keys are not included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Label("\(settingCount) settings", systemImage: "gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Enter API keys manually on iOS, or sync them through iCloud Keychain.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)

                    Text("Code expires in 10 minutes")
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
                    Text("No supported settings to transfer")
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
        .padding(24)
        .frame(width: 300)
        .task { await generateQRCode() }
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
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(payload.utf8)
            filter.correctionLevel = "M"

            guard let outputImage = filter.outputImage else {
                throw ConfigTransferError.decodingFailed
            }

            // Scale up for display
            let scale = 10.0
            let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            let rep = NSCIImageRep(ciImage: scaledImage)
            let nsImage = NSImage(size: rep.size)
            nsImage.addRepresentation(rep)
            qrImage = nsImage
        } catch {
            self.error = error.localizedDescription
        }

        isGenerating = false
    }

    private func gatherSettings() -> [String: String] {
        var settings: [String: String] = [:]

        let liveModel = appSettings.liveTranscriptionModel
        if !liveModel.isEmpty {
            settings["selectedModel"] = liveModel
        }

        return settings
    }
}

// Preview requires AppEnvironment - use in Xcode with proper setup
// #Preview {
//     ConfigTransferView()
// }
#endif
