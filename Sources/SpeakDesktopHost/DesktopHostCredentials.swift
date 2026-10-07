import Foundation
import SpeakCore
import SpeakDesktop

/// Provider API keys typed in the window.
extension DesktopHostController {
    package func saveKey(_ key: String, modelIndex: Int) async {
        guard !closed, !busy, recording == nil else { return }
        do {
            guard DesktopHostModels.all.indices.contains(modelIndex),
                  let provider = DesktopHostModels.provider(
                    for: DesktopHostModels.all[modelIndex].id
                  ) else { throw DesktopTranscriptionError.unsupportedModel }
            let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, provider.apiKeyIdentifier == AzureSpeechConfiguration.credentialIdentifier {
                _ = try AzureSpeechConfiguration(credentials: cleaned)
            }
            if let saveByHand = cloudSync.saveKeyByHand {
                // With iCloud sync, the key and its "saved by hand" mark change in
                // one step, so a deletion synced from the Mac cannot remove it.
                try await saveByHand(cleaned, provider.apiKeyIdentifier)
            } else {
                try Platform.saveAPIKey(cleaned, name: provider.apiKeyIdentifier)
            }
            if provider.id == OpenRouterService.providerID { refreshModels(force: true) }
            update(cleaned.isEmpty ? "API key removed." : "API key saved in \(Platform.credentialStoreName).")
        } catch { update(error.localizedDescription) }
    }
}
