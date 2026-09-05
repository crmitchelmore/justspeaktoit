#if os(iOS)
import SpeakCore
import SwiftUI

/// Both settings entry points update the same normal recording and voice-output preferences.
struct IOSOpenRouterAudioSettingsLink: View {
    var forSpeech = false

    var body: some View {
        NavigationLink {
            IOSOpenRouterAudioSettingsView(forSpeech: forSpeech)
        } label: {
            Label("Browse OpenRouter Audio", systemImage: "waveform")
        }
        .accessibilityIdentifier("openRouterAudioBrowserLink")
    }
}

struct IOSOpenRouterAudioSettingsView: View {
    let forSpeech: Bool
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var voiceSettings = OpenClawSettings.shared

    var body: some View {
        OpenRouterAudioBrowser(
            apiKeyProvider: {
                await AppSettings.shared.ensureKeysLoaded()
                return await AppSettings.shared.openRouterAPIKey
            },
            selectedTranscriptionID: settings.batchTranscriptionModel,
            selectedSpeechID: voiceSettings.ttsProvider == .openrouter ? voiceSettings.ttsModel : nil,
            onSelectTranscription: forSpeech ? nil : { identifier in
                settings.selectOpenRouterTranscription(identifier)
            },
            onSelectSpeech: forSpeech ? { identifier in
                voiceSettings.selectOpenRouterSpeech(identifier)
            } : nil
        )
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

extension OpenClawSettings {
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

    static func supportsBatchModel(_ identifier: String) -> Bool {
        OpenRouterTranscriptionSelection.modelID(from: identifier) != nil
            || supportedBatchModels.contains { $0.id == identifier }
    }
}
#endif
