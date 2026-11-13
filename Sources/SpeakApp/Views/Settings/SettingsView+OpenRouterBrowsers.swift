import SpeakCore
import SwiftUI

/// The live discover-then-configure browsers behind the separate Browse OpenRouter
/// buttons of the cleanup and batch transcription pickers.
extension SettingsView {
  var cleanupOpenRouterBrowser: ModelPickerOpenRouterBrowser {
    { select in
      AnyView(
        OpenRouterCleanupBrowser(
          selection: settings.postProcessingModel,
          discoveryEnabled: settingsBinding(\AppSettings.cleanupModelDiscoveryEnabled),
          options: { [settings] in CleanupModelDiscoveryStore.shared.options(selected: settings.postProcessingModel) },
          temperature: settingsBinding(\AppSettings.postProcessingTemperature),
          onSelect: select
        )
      )
    }
  }

  var batchTranscriptionOpenRouterBrowser: ModelPickerOpenRouterBrowser {
    { select in
      AnyView(
        OpenRouterTranscriptionBrowser(
          apiKeyProvider: { [storage = environment.secureStorage] in
            try? await storage.secret(identifier: "openrouter.apiKey")
          },
          selection: settings.batchTranscriptionModel,
          bundled: ModelCatalog.batchTranscription,
          onSelect: select
        )
      )
    }
  }

  /// The batch catalogue plus a saved live-discovered OpenRouter choice, so the
  /// picker names it rather than showing it as a custom identifier.
  var batchTranscriptionOptions: [ModelCatalog.Option] {
    let selected = settings.batchTranscriptionModel
    guard let modelID = OpenRouterTranscriptionSelection.modelID(from: selected) else {
      return ModelCatalog.batchTranscription
    }
    return ModelCatalog.batchTranscription + [
      .init(id: selected, displayName: modelID, description: "Discovered OpenRouter speech-to-text model.")
    ]
  }
}
