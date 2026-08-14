#if os(iOS)
// swiftlint:disable file_length
import SpeakCore
import SwiftUI

// MARK: - OpenClaw Settings View

// swiftlint:disable:next type_body_length
public struct OpenClawSettingsView: View {
    @ObservedObject private var settings = OpenClawSettings.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tokenInput = ""
    @State private var urlInput = ""
    @State private var testState: OpenClawConnectionTester.Outcome = .idle
    @State private var voiceTestState: VoiceTestState = .idle
    @State private var sonioxAccountVoices: [SonioxTTSAccountVoice] = []
    @State private var loadedSonioxDiscoveryID: String?

    enum VoiceTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    public init() {}

    public var body: some View {
        Form {
            Section("Gateway Connection") {
                Toggle(isOn: $settings.enabled) {
                    Label("Enable OpenClaw", systemImage: "bolt.horizontal.icloud")
                }

                TextField("host:port or wss://hostname", text: $urlInput)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onAppear { urlInput = settings.gatewayURL }
                    .onChange(of: urlInput) { _, newValue in
                        settings.gatewayURL = newValue
                        testState = .idle
                    }

                if !usesInlineDensityLayout {
                    Text("Enter host:port for local connections or a Tailscale/public hostname. "
                         + "The ws:// or wss:// prefix is added automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SecureField("Gateway Token", text: $tokenInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .onAppear { tokenInput = settings.token.isEmpty ? "" : "••••••••" }

                if !tokenInput.isEmpty && tokenInput != "••••••••" {
                    Button("Save Token") {
                        settings.token = tokenInput
                        tokenInput = "••••••••"
                    }
                }

                // Test Connection
                Button {
                    if !tokenInput.isEmpty && tokenInput != "••••••••" {
                        settings.token = tokenInput
                        tokenInput = "••••••••"
                    }
                    Task { await testConnection() }
                } label: {
                    HStack {
                        switch testState {
                        case .idle:
                            Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                        case .testing:
                            ProgressView()
                                .controlSize(.small)
                            Text("Testing…")
                        case .success(let msg):
                            Label(msg, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .disabled(settings.gatewayURL.isEmpty || settings.token.isEmpty || testState == .testing)

                // Status
                HStack {
                    Text("Status")
                    Spacer()
                    Text(settings.isConfigured ? "Configured" : "Not Configured")
                        .foregroundStyle(settings.isConfigured ? .green : .secondary)
                }
            }

            Section("Voice Output") {
                Toggle(isOn: $settings.ttsEnabled) {
                    Label("Read Responses Aloud", systemImage: "speaker.wave.2")
                }

                if settings.ttsEnabled {
                    Picker("Provider", selection: $settings.ttsProvider) {
                        ForEach(VoiceOutputProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: settings.ttsProvider) { _ in
                        settings.validateVoiceModelCombination()
                        voiceTestState = .idle
                    }

                    if settings.ttsProvider == .deepgram {
                        Picker("Voice", selection: $settings.ttsVoice) {
                            ForEach(DeepgramTTSCatalog.voices(forModelID: settings.ttsModel)) { voice in
                                voiceLabel(voice.displayName, credentialID: "deepgram/\(voice.id)")
                                    .tag(voice.id)
                            }
                        }
                        .onChange(of: settings.ttsVoice) { _ in
                            settings.validateVoiceModelCombination()
                        }

                        Picker("Model", selection: $settings.ttsModel) {
                            ForEach(DeepgramTTSCatalog.models) { model in
                                voiceLabel(model.displayName, credentialID: "deepgram/\(model.id)")
                                    .tag(model.id)
                            }
                        }
                        .onChange(of: settings.ttsModel) { _ in
                            settings.validateVoiceModelCombination()
                        }
                    } else {
                        Picker("Voice", selection: $settings.ttsVoice) {
                            ForEach(OpenClawSettings.sonioxBuiltInVoices) { voice in
                                voiceLabel(voice.displayName, credentialID: voice.providerVoiceID)
                                    .tag(voice.providerVoiceID)
                            }
                            ForEach(readySonioxAccountVoices) { voice in
                                voiceLabel("\(voice.name) (Cloned)", credentialID: voice.providerVoiceID)
                                    .tag(voice.providerVoiceID)
                            }
                            if selectedSonioxVoiceIsUnavailable {
                                Text("\(settings.ttsVoiceName) (Unavailable; uses Maya)")
                                    .tag(settings.ttsVoice)
                            }
                        }
                        .onChange(of: settings.ttsVoice) { _, voiceID in
                            rememberSonioxVoiceName(voiceID)
                        }

                        Picker("Region", selection: $settings.sonioxRegion) {
                            ForEach(SonioxTTSRegion.allCases) { region in
                                Text(region.displayName).tag(region)
                            }
                        }
                    }

                    Picker("Language", selection: $settings.ttsLanguageIdentifier) {
                        ForEach(VoiceOutputLanguageCatalog.options) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text(String(format: "%.1f×", settings.ttsSpeed))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.ttsSpeed, in: settings.ttsProvider.speedRange, step: 0.1)
                    }

                    if !usesInlineDensityLayout {
                        Text(
                            "Requires a \(settings.ttsProvider.displayName) API key in the main app settings."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await testVoice() }
                    } label: {
                        HStack {
                            switch voiceTestState {
                            case .idle:
                                Label("Test Voice", systemImage: "play.circle")
                            case .testing:
                                ProgressView()
                                    .controlSize(.small)
                                Text("Speaking…")
                            case .success:
                                Label("Voice OK", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .failure(let msg):
                                Label(msg, systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .disabled(!selectedProviderHasKey || voiceTestState == .testing)
                }

                Toggle(isOn: $settings.summariseResponses) {
                    Label("Summarise for Voice", systemImage: "text.quote")
                }

                if settings.summariseResponses && !usesInlineDensityLayout {
                    Text(
                        "Long responses will be summarised into concise voice-friendly text "
                            + "before speaking (requires OpenRouter API key)."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.lowLatencySpeech) {
                    Label("Prioritise Low Latency", systemImage: "hare")
                }

                if settings.lowLatencySpeech && !usesInlineDensityLayout {
                    Text("Skips the extra summarisation step before speaking for faster responses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hands-Free Conversation") {
                Toggle(isOn: $settings.conversationModeEnabled) {
                    Label("Conversation Mode", systemImage: "checkmark.square")
                }

                Toggle(isOn: $settings.autoResumeListening) {
                    Label("Auto-Resume Listening", systemImage: "arrow.clockwise.circle")
                }
                .disabled(!settings.conversationModeEnabled)

                Toggle(isOn: $settings.headsetSingleTapAcknowledge) {
                    Label("Headset Pause Acknowledge", systemImage: "pause.circle")
                }
                .disabled(!settings.conversationModeEnabled)

                Toggle(isOn: $settings.keywordAcknowledgeEnabled) {
                    Label("Keyword Acknowledge", systemImage: "waveform.and.mic")
                }
                .disabled(!settings.conversationModeEnabled)

                if settings.keywordAcknowledgeEnabled && settings.conversationModeEnabled {
                    TextField("Keyword (for example: over)", text: $settings.keywordAcknowledgePhrase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            if !usesInlineDensityLayout {
                Section("How It Works") {
                    VStack(alignment: .leading, spacing: 8) {
                        InfoStepRow(number: 1, text: "Tap the mic to record your voice message")
                        InfoStepRow(number: 2, text: "Your speech is transcribed using your selected model")
                        InfoStepRow(number: 3, text: "The text is sent to your OpenClaw agent")
                        InfoStepRow(number: 4, text: "The response is spoken back to you")
                        InfoStepRow(number: 5, text: "In conversation mode, listening can restart automatically")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .environment(\.defaultMinListRowHeight, appSettings.visualDensity.minimumListRowHeight)
        .listSectionSpacing(appSettings.visualDensity.listSectionSpacing)
        .navigationTitle("OpenClaw Settings")
        .navigationBarTitleDisplayMode(.inline)
        .controlSize(appSettings.visualDensity.isCompact ? .small : .regular)
        .task(id: sonioxDiscoveryID) {
            await refreshSonioxAccountVoices()
        }
    }

    private var usesInlineDensityLayout: Bool {
        appSettings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
    }

    private var readySonioxAccountVoices: [SonioxTTSAccountVoice] {
        sonioxAccountVoices.filter { $0.status(for: SonioxTTSCatalog.defaultModel) == .ready }
    }

    private var selectedSonioxVoiceIsUnavailable: Bool {
        guard settings.ttsProvider == .soniox,
              loadedSonioxDiscoveryID == sonioxDiscoveryID,
              SonioxTTSCatalog.voice(forID: settings.ttsVoice) == nil else {
            return false
        }
        return !readySonioxAccountVoices.contains { $0.providerVoiceID == settings.ttsVoice }
    }

    private var selectedProviderHasKey: Bool {
        switch settings.ttsProvider {
        case .deepgram: appSettings.hasDeepgramKey
        case .soniox: appSettings.hasSonioxKey
        }
    }

    private var sonioxDiscoveryID: String {
        "\(settings.ttsProvider.rawValue):\(settings.sonioxRegion.rawValue):\(appSettings.hasSonioxKey)"
    }

    @ViewBuilder
    private func voiceLabel(_ title: String, credentialID: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            IOSModelCredentialStatusView(
                availability: ModelCredentialResolver.availability(
                    for: credentialID,
                    purpose: .voiceOutput,
                    storedAPIKeyIdentifiers: appSettings.storedAPIKeyIdentifiers
                )
            )
        }
        .accessibilityElement(children: .combine)
    }

    private func rememberSonioxVoiceName(_ voiceID: String) {
        if let builtIn = SonioxTTSCatalog.voice(forID: voiceID) {
            settings.ttsVoiceName = builtIn.displayName
        } else if let account = readySonioxAccountVoices.first(where: { $0.providerVoiceID == voiceID }) {
            settings.ttsVoiceName = account.name
        }
    }

    private func refreshSonioxAccountVoices() async {
        let discoveryID = sonioxDiscoveryID
        loadedSonioxDiscoveryID = nil
        guard settings.ttsProvider == .soniox else { return }
        await appSettings.ensureKeysLoaded()
        guard !Task.isCancelled, discoveryID == sonioxDiscoveryID else { return }
        guard appSettings.hasSonioxKey else {
            sonioxAccountVoices = []
            loadedSonioxDiscoveryID = discoveryID
            return
        }
        do {
            let client = SonioxIOSVoiceOutputClient()
            let voices = try await client.listAccountVoices(
                apiKey: appSettings.sonioxAPIKey,
                region: settings.sonioxRegion
            )
            guard !Task.isCancelled, discoveryID == sonioxDiscoveryID else { return }
            sonioxAccountVoices = voices
            rememberSonioxVoiceName(settings.ttsVoice)
        } catch {
            guard !Task.isCancelled, discoveryID == sonioxDiscoveryID else { return }
            sonioxAccountVoices = []
        }
        loadedSonioxDiscoveryID = discoveryID
    }

    // MARK: - Connection Test

    private func testConnection() async {
        testState = .testing
        testState = await OpenClawConnectionTester.test(
            rawURL: settings.gatewayURL,
            token: settings.token
        )
    }

    // MARK: - Voice Test

    private func testVoice() async {
        voiceTestState = .testing
        let tts = VoiceOutputRouter()

        do {
            try await tts.speak(
                text: "Hello, this is a voice test.",
                provider: settings.ttsProvider,
                model: settings.ttsModel,
                voice: settings.ttsVoice,
                lastKnownVoiceName: settings.ttsVoiceName,
                speed: settings.ttsSpeed,
                languageIdentifier: settings.ttsLanguageIdentifier,
                sonioxRegion: settings.sonioxRegion,
                deepgramAPIKey: appSettings.deepgramAPIKey,
                sonioxAPIKey: appSettings.sonioxAPIKey
            )
            voiceTestState = .success
        } catch {
            voiceTestState = .failure(error.localizedDescription)
        }
    }
}

struct InfoStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Settings") {
    NavigationStack {
        OpenClawSettingsView()
    }
}
#endif
