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
                let model = DesktopHostModels.all[modelIndex].id
                if AzureTranscriptionModels.batchIDs.contains(model) {
                    _ = try AzureSpeechConfiguration.batchConnection(
                        credentials: cleaned, endpoint: azureResourceEndpoint()
                    )
                } else {
                    _ = try AzureSpeechConfiguration.liveConnection(
                        credentials: cleaned, endpoint: azureResourceEndpoint()
                    )
                }
            }
            try await writeProviderAPIKey(cleaned, identifier: provider.apiKeyIdentifier)
            guard !closed, !Task.isCancelled else { return }
            if provider.id == OpenRouterService.providerID { refreshModels(force: true) }
            update(cleaned.isEmpty ? "API key removed." : "API key saved in \(Platform.credentialStoreName).")
            await refreshComparison()
        } catch { update(error.localizedDescription) }
    }
}
