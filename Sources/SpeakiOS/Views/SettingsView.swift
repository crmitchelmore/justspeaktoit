#if os(iOS)
import SpeakCore
import SpeakSync
import SwiftUI

// swiftlint:disable file_length

// swiftlint:disable:next type_body_length
public struct SettingsView: View {
    /// Names the provider whose key the selected batch model needs, read from
    /// the same canonical resolver `batchAPIKey(for:)` uses. Deriving it means
    /// a provider added to the batch catalogue cannot silently inherit the
    /// OpenRouter wording while its request goes somewhere else.
    static func batchAPIKeyPrompt(for modelIdentifier: String) -> String {
        switch ModelCredentialResolver.requirement(
            for: modelIdentifier,
            purpose: .batchTranscription
        ) {
        case .notRequired:
            return "This model runs on device and needs no API key."
        case .apiKey(_, let providerName):
            return "Add your \(providerName) API key below to use this model."
        }
    }

    @StateObject private var settings = AppSettings.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.openClawEnabled) private var openClawEnabled
    @Environment(\.iOSKeyboardEnabled) private var iOSKeyboardEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingAPIKeys = false
    @State private var missingTranscriptionAPIKeyAlert: IOSMissingTranscriptionAPIKeyAlert?

    public init() {}

    public var body: some View {
        Form {
            Section("Appearance") {
                Picker("Layout Density", selection: $settings.visualDensity) {
                    ForEach(AppVisualDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.segmented)

                if !usesInlineDensityLayout {
                    Text(
                        "Compact restructures screens around inline controls, shorter cards, "
                            + "and grouped status rows while keeping controls easy to tap."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Language") {
                Picker("Spoken Language", selection: $settings.preferredLocaleIdentifier) {
                    ForEach(TranscriptionLanguageCatalog.options) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("spokenLanguagePicker")

                if !usesInlineDensityLayout {
                    Text(
                        "Automatic lets remote providers detect the language. "
                            + "Apple on-device transcription uses your current system locale."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Transcription") {
                Picker("Where transcription runs", selection: transcriptionLocationBinding) {
                    ForEach(IOSTranscriptionLocation.allCases) { location in
                        Text(location.displayName).tag(location)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("transcriptionLocationPicker")

                if transcriptionLocationBinding.wrappedValue == .local {
                    Picker("Apple Speech Model", selection: selectedModelBinding) {
                        ForEach(ModelCatalog.onDeviceLiveTranscription) { option in
                            HStack {
                                Text(option.displayName)
                                Spacer()
                                IOSModelCredentialStatusView(
                                    availability: ModelCredentialResolver.availability(
                                        for: option.id,
                                        purpose: .liveTranscription,
                                        storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                                    )
                                )
                            }
                            .accessibilityElement(children: .combine)
                            .tag(option.id)
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

                    if !usesInlineDensityLayout {
                        Text(
                            "Uses Apple's on-device speech engines when available. "
                                + "If recognition is unavailable or fails, audio may be sent to Apple."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Remote Mode", selection: remoteTranscriptionModeBinding) {
                        ForEach(IOSTranscriptionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("remoteTranscriptionModePicker")

                    if settings.transcriptionMode == .streaming {
                        Picker("Remote Streaming Model", selection: selectedModelBinding) {
                            ForEach(LiveModelGroup.grouped(AppSettings.supportedLiveModels)) { group in
                                Section(group.title) {
                                    ForEach(group.options) { option in
                                        HStack {
                                            Text(option.displayName)
                                            Spacer()
                                            IOSModelCredentialStatusView(
                                                availability: ModelCredentialResolver.availability(
                                                    for: option.id,
                                                    purpose: .liveTranscription,
                                                    storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                                                )
                                            )
                                        }
                                        .accessibilityElement(children: .combine)
                                        .tag(option.id)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("remoteStreamingModelPicker")
                    } else {
                        Picker("Remote Batch Model", selection: $settings.batchTranscriptionModel) {
                            if let modelID = OpenRouterTranscriptionSelection.modelID(
                                from: settings.batchTranscriptionModel
                            ) {
                                Text("OpenRouter · \(modelID)")
                                    .tag(settings.batchTranscriptionModel)
                            }
                            ForEach(BatchModelGroup.grouped(AppSettings.supportedBatchModels)) { group in
                                Section(group.title) {
                                    ForEach(group.options) { option in
                                        HStack {
                                            Text(ModelCatalog.friendlyName(for: option.id))
                                            Spacer()
                                            IOSModelCredentialStatusView(
                                                availability: ModelCredentialResolver.availability(
                                                    for: option.id,
                                                    purpose: .batchTranscription,
                                                    storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                                                )
                                            )
                                        }
                                        .accessibilityElement(children: .combine)
                                        .tag(option.id)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("remoteBatchModelPicker")
                        IOSOpenRouterAudioSettingsLink()
                    }

                    if !usesInlineDensityLayout {
                        Text(settings.transcriptionMode == .streaming
                            ? "Text appears while audio is streamed to the selected provider."
                            : "Audio is uploaded after recording for a more complete transcript.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if transcriptionLocationBinding.wrappedValue == .remote,
                   settings.transcriptionMode == .streaming,
                   let route = LiveTranscriptionRouting.route(for: settings.selectedModel),
                   route.isSupportedOnIOS,
                   route.apiKeyIdentifier != nil,
                   settings.liveAPIKey(for: route).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(
                        "Add this provider's API key below to use this model.",
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
                        Self.batchAPIKeyPrompt(for: settings.batchTranscriptionModel),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }

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
                    Text(
                        "Meta uses these names, acronyms, and domain terms as vocabulary hints. "
                            + "The Spoken Language setting above supplies its language bias."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

            }

            Section("Behavior") {
                Toggle(isOn: $settings.autoStartRecording) {
                    Label("Auto-Start Recording", systemImage: "mic.badge.plus")
                }

                if settings.autoStartRecording && !usesInlineDensityLayout {
                    Text("Recording starts automatically when you open the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.handsFreeDictationEnabled) {
                    Label("Hands-Free Dictation", systemImage: "waveform.badge.mic")
                }
                .disabled(!settings.handsFreeDictationSupported)
                .accessibilityIdentifier("handsFreeDictationToggle")

                if !usesInlineDensityLayout {
                    Text(handsFreeDictationCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.liveActivitiesEnabled) {
                    Label("Live Activities", systemImage: "platter.filled.bottom.iphone")
                }

                if settings.liveActivitiesEnabled && !usesInlineDensityLayout {
                    Text("Shows transcription progress on Lock Screen and Dynamic Island.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if iOSKeyboardEnabled {
                Section("Just Speak Keyboard") {
                    NavigationLink {
                        KeyboardSetupView()
                    } label: {
                        HStack {
                            Label("Set Up Keyboard", systemImage: "keyboard")
                            Spacer()
                            Text(keyboardStatusLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("keyboardSetupLink")

                    if !usesInlineDensityLayout {
                        Text("Transcribe into other apps through a private handoff to Just Speak.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Hardware Trigger") {
                NavigationLink {
                    HardwareTriggerSettingsView(settings: settings)
                } label: {
                    HStack {
                        Label("Action Button & Shortcuts", systemImage: "button.programmable")
                        Spacer()
                        Text(settings.hardwareTriggerDestination.displayName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("hardwareTriggerSettingsLink")

                NavigationLink {
                    AutomationGalleryView()
                } label: {
                    Label("Shortcuts Gallery", systemImage: "square.stack.3d.up")
                }
                .accessibilityIdentifier("automationGalleryLink")

                if !usesInlineDensityLayout {
                    Text(
                        "Trigger transcription from the Action Button, Siri, Lock Screen, "
                            + "Control Center, or Back Tap."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Post-Processing") {
                Toggle(isOn: $settings.autoPostProcess) {
                    Label("Auto-Polish After Recording", systemImage: "wand.and.stars")
                }

                if settings.autoPostProcess && !usesInlineDensityLayout {
                    Text("Automatically opens polish view after each recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    PostProcessingSettingsView(settings: settings)
                } label: {
                    HStack {
                        Label("Model & Prompt", systemImage: "slider.horizontal.3")
                        Spacer()
                        Text(postProcessingModelName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !settings.hasOpenRouterKey {
                    Label("OpenRouter API key required", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("API Keys") {
                if usesInlineDensityLayout {
                    NavigationLink {
                        APIKeysView(settings: settings)
                    } label: {
                        compactAPIKeySummary
                    }
                } else {
                    apiKeyStatusRow(
                        name: "Deepgram",
                        systemImage: "waveform",
                        isStored: settings.hasDeepgramKey
                    )
                    apiKeyStatusRow(
                        name: "ElevenLabs",
                        systemImage: "mic.and.signal.meter",
                        isStored: settings.hasElevenLabsKey
                    )
                    apiKeyStatusRow(
                        name: "OpenRouter",
                        systemImage: "network",
                        isStored: settings.hasOpenRouterKey
                    )
                    apiKeyStatusRow(
                        name: "OpenAI",
                        systemImage: "brain.head.profile",
                        isStored: settings.hasOpenAIKey
                    )

                    NavigationLink {
                        APIKeysView(settings: settings)
                    } label: {
                        Label("Manage Keys", systemImage: "key.viewfinder")
                    }
                }
            }

            Section("Sync") {
                // CloudKit History Sync
                CloudKitSyncSettingsSection()

                CloudKitKeySyncSettingsSection()

                // Sync status
                let syncStatus = SyncStatus.current(
                    iCloudCloudKitAvailable: HistorySyncEngine.shared.state.isCloudAvailable
                )

                if usesInlineDensityLayout {
                    compactSyncStatus(syncStatus)
                } else {
                    syncStatusRows(syncStatus)
                }

                if let lastSync = syncStatus.lastSyncDate {
                    LabeledContent("Last Sync") {
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                // QR Transfer options
                NavigationLink {
                    QRCodeGeneratorView()
                } label: {
                    Label("Share to Another Device", systemImage: "qrcode")
                }

                NavigationLink {
                    QRCodeScannerView()
                } label: {
                    Label("Import from QR Code", systemImage: "qrcode.viewfinder")
                }

                if !usesInlineDensityLayout {
                    Text("Just Speak to It uses iCloud for settings and history when available. "
                        + "If iCloud is unavailable, Bonjour Transport can send sessions to a paired Mac "
                        + "on your local network; QR transfer remains available for manual setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if openClawEnabled {
                Section("OpenClaw") {
                    NavigationLink {
                        OpenClawSettingsView()
                    } label: {
                        Label("Configure OpenClaw", systemImage: "bolt.horizontal.icloud")
                    }

                    if OpenClawSettings.shared.isConfigured {
                        Label("Connected", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Capture Health") {
                NavigationLink {
                    CaptureHealthView()
                } label: {
                    Label("Check capture is working", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("captureHealthNavLink")

                if !usesInlineDensityLayout {
                    Text(
                        "Checks the things a capture needs, runs a microphone self-test, and offers back "
                            + "any recording that was interrupted before its transcript was saved. "
                            + "Nothing on that screen leaves this device."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Recordings") {
                NavigationLink {
                    RecordingsView()
                } label: {
                    Label("Saved Recordings", systemImage: "waveform.circle")
                }

                if !usesInlineDensityLayout {
                    Text(
                        "Audio is saved locally during transcription so you can replay it, "
                            + "or transcribe it again if connectivity was lost."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Privacy & Debugging") {
                NavigationLink {
                    PrivacyView()
                } label: {
                    Label("Privacy Information", systemImage: "hand.raised")
                }

                Toggle(isOn: Binding(
                    get: { SpeakLogger.isDebugMode },
                    set: { SpeakLogger.isDebugMode = $0 }
                )) {
                    Label("Debug Logging", systemImage: "ant")
                }

                if SpeakLogger.isDebugMode && !usesInlineDensityLayout {
                    Text("Debug mode logs additional details for troubleshooting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                if usesInlineDensityLayout {
                    compactBuildSummary
                } else {
                    LabeledContent("Version") {
                        Text("\(appVersion) (\(appBuild))")
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Commit") {
                        Text(BuildInfo.gitCommitShort)
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }

                    LabeledContent("SpeakCore") {
                        Text(SpeakCore.version)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    ReleaseNotesView()
                } label: {
                    Label("Release Notes", systemImage: "sparkles")
                }
                .accessibilityHint("Shows what changed in this version and earlier versions")
            }
        }
        .environment(\.defaultMinListRowHeight, settings.visualDensity.minimumListRowHeight)
        .listSectionSpacing(settings.visualDensity.listSectionSpacing)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(usesInlineDensityLayout ? .inline : .automatic)
        .controlSize(settings.visualDensity.isCompact ? .small : .regular)
        .navigationDestination(isPresented: $showingAPIKeys) {
            APIKeysView(settings: settings)
        }
        .iosMissingTranscriptionAPIKeyAlert(
            alert: $missingTranscriptionAPIKeyAlert,
            showingAPIKeys: $showingAPIKeys,
            openURL: openURL
        )
    }

    private var batchModeDescription: String {
        if AppleLocalModels.isSpeechAnalyzerModel(settings.batchTranscriptionModel) {
            return "Audio is recorded first, then transcribed privately on this device when you stop."
        }
        return "Audio is recorded first, then uploaded when you stop for a more complete transcript."
    }

    private var postProcessingModelName: String {
        ModelCatalog.friendlyName(for: settings.postProcessingModel)
    }

    private var usesInlineDensityLayout: Bool {
        settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
    }

    /// Silence budget is read from the shared policy so the copy cannot drift
    /// from the behaviour, and matches the macOS wording.
    private var handsFreeDictationCaption: String {
        guard settings.handsFreeDictationSupported else {
            return "Requires iOS 26 or later — Apple's on-device speech detector isn't available here."
        }
        return "Arm from the microphone button. The microphone remains active while armed; "
            + "silent audio stays in memory only and is never stored or sent off-device."
    }

    private var keyboardStatusLabel: String {
        guard let observation = KeyboardHandoffStore.shared.extensionObservation() else {
            return "Not observed"
        }
        return observation.hadFullAccess ? "Full Access on" : "Full Access off"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var compactBuildSummary: some View {
        HStack(spacing: settings.visualDensity.inlineSpacing) {
            Label("\(appVersion) (\(appBuild))", systemImage: "app.badge")
            Spacer()
            Text(BuildInfo.gitCommitShort)
                .font(.caption.monospaced())
            Text("Core \(SpeakCore.version)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var compactAPIKeySummary: some View {
        HStack(spacing: settings.visualDensity.inlineSpacing) {
            Label("Manage Keys", systemImage: "key.viewfinder")
            Spacer()
            Text("\(storedAPIKeyCount)/\(managedAPIKeyCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(storedAPIKeyCount == managedAPIKeyCount ? .green : .secondary)
        }
        .accessibilityLabel(
            "\(storedAPIKeyCount) of \(managedAPIKeyCount) API keys stored. Manage keys."
        )
    }

    private var storedAPIKeyCount: Int {
        managedAPIKeyEntries.filter(\.isStored).count
    }

    private var managedAPIKeyCount: Int {
        managedAPIKeyEntries.count
    }

    private var managedAPIKeyEntries: [APIKeyListEntry] {
        APIKeysView.entries(for: settings)
    }

    private func apiKeyStatusRow(name: String, systemImage: String, isStored: Bool) -> some View {
        HStack {
            Label(name, systemImage: systemImage)
                .accessibilityLabel("\(name) API Key")
            Spacer()
            Text(isStored ? "Stored" : "Missing")
                .foregroundStyle(isStored ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func compactSyncStatus(_ status: SyncStatus) -> some View {
        HStack(spacing: settings.visualDensity.inlineSpacing) {
            Label(status.preferredBackend.displayName, systemImage: "arrow.triangle.branch")
                .lineLimit(1)
            Spacer()
            syncAvailabilityIcon(
                "key.icloud",
                available: status.iCloudKeychainAvailable,
                label: "iCloud Keychain"
            )
            syncAvailabilityIcon(
                "icloud",
                available: status.iCloudKVStoreAvailable,
                label: "iCloud Settings"
            )
            syncAvailabilityIcon(
                "network",
                available: status.transportAvailable,
                label: "Bonjour Transport"
            )
        }
        .font(.caption)
    }

    private func syncAvailabilityIcon(
        _ systemImage: String,
        available: Bool,
        label: String
    ) -> some View {
        Image(systemName: available ? systemImage : "xmark.circle")
            .foregroundStyle(available ? .green : .secondary)
            .accessibilityLabel("\(label): \(available ? "available" : "unavailable")")
    }

    private func syncStatusRows(_ status: SyncStatus) -> some View {
        Group {
            HStack {
                Label("Preferred Sync", systemImage: "arrow.triangle.branch")
                Spacer()
                Text(status.preferredBackend.displayName)
                    .foregroundStyle(status.preferredBackend != .localOnly ? .green : .secondary)
            }
            .accessibilityElement(children: .combine)

            syncStatusRow(
                name: "iCloud Keychain",
                systemImage: "key.icloud",
                value: status.iCloudKeychainAvailable ? "Available" : "Local only",
                isAvailable: status.iCloudKeychainAvailable
            )
            syncStatusRow(
                name: "iCloud Settings",
                systemImage: "icloud",
                value: status.iCloudKVStoreAvailable ? "Available" : "Local only",
                isAvailable: status.iCloudKVStoreAvailable
            )
            syncStatusRow(
                name: "Bonjour Transport",
                systemImage: "network",
                value: status.transportAvailable ? "Ready" : "Unavailable",
                isAvailable: status.transportAvailable
            )
        }
    }

    private func syncStatusRow(
        name: String,
        systemImage: String,
        value: String,
        isAvailable: Bool
    ) -> some View {
        HStack {
            Label(name, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(isAvailable ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}

private extension SettingsView {
    @MainActor
    private var transcriptionLocationBinding: Binding<IOSTranscriptionLocation> {
        Binding(
            get: { settings.transcriptionLocation },
            set: { settings.selectTranscriptionLocation($0) }
        )
    }

    @MainActor
    private var remoteTranscriptionModeBinding: Binding<IOSTranscriptionMode> {
        Binding(
            get: { settings.remoteTranscriptionMode },
            set: { settings.selectRemoteTranscriptionMode($0) }
        )
    }

    @MainActor
    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { settings.selectedModel },
            set: { newValue in
                settings.selectedModel = newValue
                presentMissingTranscriptionAPIKeyAlertIfNeeded(for: newValue)
            }
        )
    }

    @MainActor
    private func presentMissingTranscriptionAPIKeyAlertIfNeeded(for model: String) {
        guard let alert = IOSMissingTranscriptionAPIKeyAlert(modelID: model, settings: settings) else {
            return
        }
        missingTranscriptionAPIKeyAlert = alert
    }
}

#endif
