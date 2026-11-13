import SpeakCore
import SwiftUI

/// The live discover-then-configure browsers behind the separate Browse OpenRouter
/// buttons of the cleanup and batch transcription pickers.
extension SettingsView {
  var cleanupOpenRouterBrowser: ModelPickerOpenRouterBrowser {
    ModelPickerOpenRouterBrowsers.cleanup(
      selection: settings.postProcessingModel,
      discoveryEnabled: settingsBinding(\AppSettings.cleanupModelDiscoveryEnabled),
      temperature: settingsBinding(\AppSettings.postProcessingTemperature)
    )
  }

  var batchTranscriptionOpenRouterBrowser: ModelPickerOpenRouterBrowser {
    ModelPickerOpenRouterBrowsers.batchTranscription(
      selection: settings.batchTranscriptionModel, storage: environment.secureStorage
    )
  }

  var batchTranscriptionOptions: [ModelCatalog.Option] {
    ModelPickerOpenRouterBrowsers.batchOptions(selected: settings.batchTranscriptionModel)
  }
}

/// Browser builders shared by the settings pickers and the profile editor.
@MainActor
enum ModelPickerOpenRouterBrowsers {
  static func cleanup(
    selection: String, discoveryEnabled: Binding<Bool>, temperature: Binding<Double>?
  ) -> ModelPickerOpenRouterBrowser {
    { select in
      AnyView(
        OpenRouterCleanupBrowser(
          selection: selection,
          discoveryEnabled: discoveryEnabled,
          options: { CleanupModelDiscoveryStore.shared.options(selected: selection) },
          temperature: temperature,
          onSelect: select
        )
      )
    }
  }

  static func batchTranscription(selection: String, storage: SecureAppStorage) -> ModelPickerOpenRouterBrowser {
    { select in
      AnyView(
        OpenRouterTranscriptionBrowser(
          apiKeyProvider: { try? await storage.secret(identifier: "openrouter.apiKey") },
          selection: selection,
          bundled: ModelCatalog.batchTranscription,
          onSelect: select
        )
      )
    }
  }

  /// The batch catalogue plus a saved live-discovered OpenRouter choice, so the
  /// picker names it rather than showing it as a custom identifier.
  static func batchOptions(selected: String) -> [ModelCatalog.Option] {
    guard let modelID = OpenRouterTranscriptionSelection.modelID(from: selected) else {
      return ModelCatalog.batchTranscription
    }
    return ModelCatalog.batchTranscription + [
      .init(id: selected, displayName: modelID, description: "Discovered OpenRouter speech-to-text model.")
    ]
  }

  /// Cleanup catalogue options plus a saved discovered choice, so a picker
  /// without a Custom entry keeps it rather than replacing it.
  static func cleanupOptions(_ base: [ModelCatalog.Option], selected: String) -> [ModelCatalog.Option] {
    guard !base.contains(where: { $0.id == selected }),
      let retained = CleanupModelSelection.retainedOption(selected) else { return base }
    return base + [retained]
  }
}

/// The separate Browse OpenRouter models button below a model picker, matching
/// the voice section's Browse OpenRouter Speech… button.
struct ModelPickerOpenRouterButton: View {
  let identifier: String
  let browser: ModelPickerOpenRouterBrowser
  @Binding var value: String
  @State private var isPresented = false

  var body: some View {
    Button("Browse OpenRouter models…") { isPresented = true }
      .buttonStyle(.bordered)
      .accessibilityIdentifier(identifier)
      .sheet(isPresented: $isPresented) {
        browser { value = $0 }
      }
  }
}
