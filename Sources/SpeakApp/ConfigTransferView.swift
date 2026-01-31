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
                    
                    HStack(spacing: 16) {
                        Label("\(secretCount) API keys", systemImage: "key.fill")
                        Label("\(settingCount) settings", systemImage: "gearshape")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    
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
        .padding(24)
        .frame(width: 300)
        .task { await generateQRCode() }
    }
    
    private func generateQRCode() async {
        isGenerating = true
        error = nil
        
        do {
            // Gather secrets
            let secrets = await gatherSecrets()
            let settings = gatherSettings()
            
            secretCount = secrets.count
            settingCount = settings.count
            
            guard !secrets.isEmpty || !settings.isEmpty else {
                qrImage = nil
                isGenerating = false
                return
            }
            
            let payload = try ConfigTransferManager.shared.generatePayload(
                secrets: secrets,
                settings: settings
            )
            
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
            
            let rep = NSCIImageRep(ciImage: scaledImage)
            let nsImage = NSImage(size: rep.size)
            nsImage.addRepresentation(rep)
            qrImage = nsImage
        } catch {
            self.error = error.localizedDescription
        }
        
        isGenerating = false
    }
    
    private func gatherSecrets() async -> [String: String] {
        var secrets: [String: String] = [:]
        
        // Key identifiers used by both macOS and iOS
        let knownKeys = [
            "deepgram.apiKey",
            "openrouter.apiKey",
            "openai.apiKey",
            "openai.tts.apiKey",
            "elevenlabs.apiKey",
            "azure.speech.apiKey"
        ]
        
        for key in knownKeys {
            if let value = try? await secureStorage.secret(identifier: key), !value.isEmpty {
                secrets[key] = value
            }
        }
        
        return secrets
    }
    
    private func gatherSettings() -> [String: String] {
        var settings: [String: String] = [:]
        let defaults = UserDefaults.standard
        
        // Settings that make sense to transfer to iOS
        if let liveModel = defaults.string(forKey: "liveTranscriptionModel") {
            settings["selectedModel"] = liveModel
        }
        
        return settings
    }
}

// Preview requires AppEnvironment - use in Xcode with proper setup
// #Preview {
//     ConfigTransferView(secureStorage: ...)
// }
#endif
