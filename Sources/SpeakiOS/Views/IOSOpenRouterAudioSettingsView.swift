#if os(iOS)
import SpeakCore
import SwiftUI

/// The separate Browse OpenRouter models link under the Remote Batch Model picker:
/// bundled OpenRouter models first, then the live speech-to-text catalogue.
struct IOSOpenRouterTranscriptionBrowserLink: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        NavigationLink {
            OpenRouterTranscriptionBrowser(
                apiKeyProvider: {
                    await AppSettings.shared.ensureKeysLoaded()
                    return await AppSettings.shared.openRouterAPIKey
                },
                selection: settings.batchTranscriptionModel,
                bundled: AppSettings.supportedBatchModels,
                embedded: true,
                onSelect: { settings.selectOpenRouterBatchModel($0) }
            )
        } label: {
            Label("Browse OpenRouter models…", systemImage: "waveform")
        }
        .accessibilityIdentifier("openRouterAudioBrowserLink")
    }
}

struct IOSOpenRouterSpeechSelectionLabel: View {
    let selectionID: String

    var body: some View {
        if let selection = OpenRouterSpeechSelection(id: selectionID) {
            LabeledContent("Model", value: selection.modelID)
            LabeledContent("Voice", value: selection.voice ?? "Provider default")
        } else {
            Text("Choose a speech model and voice in Browse OpenRouter Audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension IOSVoiceOutputSettings {
    func selectOpenRouterSpeech(_ identifier: String) {
        guard let selection = OpenRouterSpeechSelection(id: identifier) else { return }
        ttsModel = selection.id
        ttsVoice = selection.voice ?? ""
        ttsVoiceName = selection.voice ?? "Provider default"
        ttsProvider = .openrouter
    }
}

extension AppSettings {
    func selectOpenRouterTranscription(_ identifier: String) {
        guard OpenRouterTranscriptionSelection.modelID(from: identifier) != nil else { return }
        batchTranscriptionModel = identifier
        selectRemoteTranscriptionMode(.batch)
    }

    /// A bundled OpenRouter batch model or a live-discovered one, from the browser.
    func selectOpenRouterBatchModel(_ identifier: String) {
        guard Self.supportsBatchModel(identifier) else { return }
        batchTranscriptionModel = identifier
        selectRemoteTranscriptionMode(.batch)
    }

    static func supportsBatchModel(_ identifier: String) -> Bool {
        OpenRouterTranscriptionSelection.modelID(from: identifier) != nil
            || supportedBatchModels.contains { $0.id == identifier }
    }
}
#endif
