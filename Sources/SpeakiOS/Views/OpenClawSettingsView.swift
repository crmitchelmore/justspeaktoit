#if os(iOS)
import SpeakCore
import SwiftUI

// MARK: - OpenClaw Settings View

public struct OpenClawSettingsView: View {
    @ObservedObject private var settings = OpenClawSettings.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @State private var tokenInput = ""
    @State private var urlInput = ""
    @State private var testState: OpenClawConnectionTester.Result = .idle
    @State private var voiceTestState: VoiceTestState = .idle

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

                Text("Enter host:port for local connections or a Tailscale/public hostname. "
                     + "The ws:// or wss:// prefix is added automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                    Picker("Voice", selection: $settings.ttsVoice) {
                        ForEach(
                            OpenClawSettings.voices(for: settings.ttsModel),
                            id: \.id
                        ) { voice in
                            Text(voice.label).tag(voice.id)
                        }
                    }

                    Picker("Model", selection: $settings.ttsModel) {
                        ForEach(OpenClawSettings.availableModels, id: \.id) { mdl in
                            Text(mdl.label).tag(mdl.id)
                        }
                    }
                    .onChange(of: settings.ttsModel) { _ in
                        settings.validateVoiceModelCombination()
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text(String(format: "%.1f×", settings.ttsSpeed))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.ttsSpeed, in: 0.5...2.0, step: 0.1)
                    }

                    Text(
                        "Requires a Deepgram API key in the main app settings."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                    .disabled(!appSettings.hasDeepgramKey || voiceTestState == .testing)
                }

                Toggle(isOn: $settings.summariseResponses) {
                    Label("Summarise for Voice", systemImage: "text.quote")
                }

                if settings.summariseResponses {
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

                if settings.lowLatencySpeech {
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
        .navigationTitle("OpenClaw Settings")
        .navigationBarTitleDisplayMode(.inline)
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
        let tts = DeepgramTTSClient()
        tts.model = settings.ttsModel
        tts.voice = settings.ttsVoice
        tts.speed = settings.ttsSpeed

        do {
            try await tts.speak(
                text: "Hello, this is a voice test.",
                apiKey: appSettings.deepgramAPIKey
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
