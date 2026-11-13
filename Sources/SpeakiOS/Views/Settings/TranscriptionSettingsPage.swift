#if os(iOS)
import SpeakCore
import SwiftUI

struct GeneralSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SearchableSettingsSection("Appearance") {
            Picker("Layout Density", selection: $settings.visualDensity) {
                ForEach(AppVisualDensity.allCases) { density in
                    Text(density.displayName).tag(density)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Layout Density")
            .accessibilityIdentifier("layoutDensityPicker")

            SettingsFootnote("**Compact** fits more on screen with inline controls and shorter cards.")
        }

        SearchableSettingsSection("Language") {
            Picker("Spoken Language", selection: $settings.preferredLocaleIdentifier) {
                ForEach(TranscriptionLanguageCatalog.options) { option in
                    Text(option.displayName).tag(option.id)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("spokenLanguagePicker")

            SettingsFootnote(
                "**Automatic** lets remote providers detect the language; "
                    + "Apple on-device transcription then uses your iPhone's language."
            )
        }
    }
}

struct TranscriptionSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openURL) private var openURL
    @State private var showingAPIKeys = false
    @State private var missingTranscriptionAPIKeyAlert: IOSMissingTranscriptionAPIKeyAlert?

    /// Whether the model pickers are hidden because Simple model choices is on
    /// and paid routing is actually available.
    private var hidesModelSelection: Bool {
        PaidAccessStore.shared.simpleModelChoicesPolicy.hidesModelSelection
    }

    var body: some View {
        SearchableSettingsSection("Transcription") {
            Picker("Where transcription runs", selection: transcriptionLocationBinding) {
                ForEach(IOSTranscriptionLocation.allCases) { location in
                    Text(location.displayName).tag(location)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Where transcription runs")
            .accessibilityIdentifier("transcriptionLocationPicker")

            SettingsFootnote(
                "**Recommended:** **Remote** with **Streaming** shows text as you speak. "
                    + "Choose **Local** to keep audio on this iPhone with no API key."
            )

            if hidesModelSelection {
                Text(PaidAccessStore.shared.simpleModelChoicesPolicy.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if transcriptionLocationBinding.wrappedValue == .local {
                localModelRows
            } else {
                remoteModelRows
            }

            missingKeyWarnings
            keywordRows
        }
        .navigationDestination(isPresented: $showingAPIKeys) {
            APIKeysView(settings: settings)
        }
        .iosMissingTranscriptionAPIKeyAlert(
            alert: $missingTranscriptionAPIKeyAlert,
            showingAPIKeys: $showingAPIKeys,
            openURL: openURL
        )
    }

    @ViewBuilder
    private var localModelRows: some View {
        // Never hidden: on-device transcription bypasses paid routing
        // entirely, so hiding this picker would leave no way to choose
        // the engine that is actually doing the work.
        Picker("Apple Speech Model", selection: selectedModelBinding) {
            ForEach(ModelCatalog.onDeviceLiveTranscription) { option in
                modelOption(option.id, name: option.displayName, purpose: .liveTranscription)
            }
        }
        .pickerStyle(.navigationLink)
        .accessibilityIdentifier("appleOnDeviceModelPicker")

        if #available(iOS 26.0, *), AppleLocalModels.isSpeechAnalyzerModel(settings.selectedModel) {
            AppleSpeechPreparationView(
                modelID: settings.selectedModel,
                localeIdentifier: settings.preferredModelLanguage ?? Locale.current.identifier
            )
        }

        SettingsFootnote(
            "Transcribes on this iPhone without uploading audio. "
                + "If on-device recognition is unavailable or fails, transcription stops."
        )
    }

    @ViewBuilder
    private var remoteModelRows: some View {
        Picker("Remote Mode", selection: remoteTranscriptionModeBinding) {
            ForEach(IOSTranscriptionMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Remote Mode")
        .accessibilityIdentifier("remoteTranscriptionModePicker")

        // Never hidden either: streaming dictation does not go through
        // the paid service, so this picker chooses the model that runs.
        if settings.transcriptionMode == .streaming {
            Picker("Remote Streaming Model", selection: selectedModelBinding) {
                ForEach(LiveModelGroup.grouped(AppSettings.supportedLiveModels)) { group in
                    Section(group.title) {
                        ForEach(group.options) { option in
                            modelOption(option.id, name: option.displayName, purpose: .liveTranscription)
                        }
                    }
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("remoteStreamingModelPicker")
        } else if !hidesModelSelection {
            Picker("Remote Batch Model", selection: $settings.batchTranscriptionModel) {
                if let modelID = OpenRouterTranscriptionSelection.modelID(from: settings.batchTranscriptionModel) {
                    Text(ModelPickerGrouping.openRouterTitle + ModelPickerGrouping.openRouterSeparator + modelID)
                        .tag(settings.batchTranscriptionModel)
                }
                ForEach(BatchModelGroup.grouped(nativeBatchModels)) { group in
                    Section(group.title) {
                        ForEach(group.options) { option in
                            modelOption(
                                option.id,
                                name: ModelCatalog.friendlyName(for: option.id),
                                purpose: .batchTranscription
                            )
                        }
                    }
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("remoteBatchModelPicker")
            IOSOpenRouterTranscriptionBrowserLink(settings: settings)
        }

        SettingsFootnote(
            settings.transcriptionMode == .streaming
                ? "**Streaming:** text appears while audio streams to the provider. "
                    + "OpenRouter models can't stream; choose Batch to use one."
                : "**Batch:** audio uploads when you stop, for a more complete transcript."
        )
    }

    /// OpenRouter batch models live behind Browse OpenRouter models…, as in the
    /// voice picker; the saved one stays listed so the picker can show it.
    private var nativeBatchModels: [ModelCatalog.Option] {
        AppSettings.supportedBatchModels.filter { option in
            !ModelPickerGrouping.isOpenRouter(option.id, purpose: .batchTranscription)
                || option.id == settings.batchTranscriptionModel
        }
    }

    @ViewBuilder
    private var missingKeyWarnings: some View {
        if transcriptionLocationBinding.wrappedValue == .remote,
           settings.transcriptionMode == .streaming,
           let route = LiveTranscriptionRouting.route(for: settings.selectedModel),
           route.isSupportedOnIOS,
           route.apiKeyIdentifier != nil,
           settings.liveAPIKey(for: route).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label(
                "Add this provider's API key in Providers & API Keys to use this model.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .font(.caption)
        }

        if transcriptionLocationBinding.wrappedValue == .remote,
           settings.transcriptionMode == .batch,
           !AppleLocalModels.isSpeechAnalyzerModel(settings.batchTranscriptionModel),
           settings.batchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label(
                SettingsView.batchAPIKeyPrompt(for: settings.batchTranscriptionModel),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var keywordRows: some View {
        let activeRemoteModel = settings.transcriptionMode == .batch
            ? settings.batchTranscriptionModel
            : settings.selectedModel
        if activeRemoteModel.hasPrefix("meta/") {
            TextField(
                "Recognition keywords (comma-separated)",
                text: $settings.transcriptionKeywords,
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            SettingsFootnote(
                "Meta uses these names, acronyms and terms as vocabulary hints. "
                    + "**Spoken Language** in General supplies its language bias.",
                alwaysShown: true
            )
        }
    }

    private func modelOption(_ id: String, name: String, purpose: ModelCredentialPurpose) -> some View {
        HStack {
            Text(name)
            Spacer()
            ModelCredentialStatusView(
                availability: ModelCredentialResolver.availability(
                    for: id,
                    purpose: purpose,
                    storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                )
            )
        }
        .accessibilityElement(children: .combine)
        .tag(id)
    }

    private var transcriptionLocationBinding: Binding<IOSTranscriptionLocation> {
        Binding(
            get: { settings.transcriptionLocation },
            set: { settings.selectTranscriptionLocation($0) }
        )
    }

    private var remoteTranscriptionModeBinding: Binding<IOSTranscriptionMode> {
        Binding(
            get: { settings.remoteTranscriptionMode },
            set: { settings.selectRemoteTranscriptionMode($0) }
        )
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { settings.selectedModel },
            set: { newValue in
                settings.selectedModel = newValue
                presentMissingTranscriptionAPIKeyAlertIfNeeded(for: newValue)
            }
        )
    }

    private func presentMissingTranscriptionAPIKeyAlertIfNeeded(for model: String) {
        guard let alert = IOSMissingTranscriptionAPIKeyAlert(modelID: model, settings: settings) else {
            return
        }
        missingTranscriptionAPIKeyAlert = alert
    }
}
#endif
