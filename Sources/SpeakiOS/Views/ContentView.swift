#if os(iOS)
import SwiftUI
import SpeakCore

// swiftlint:disable file_length
/// Unified transcriber that switches between Apple Speech and Deepgram.
/// Integrates with Live Activity for lock screen presence.
@MainActor
final class TranscriberCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var partialText = ""
    @Published private(set) var error: Error?
    @Published private(set) var currentModel: String = "apple/local/SFSpeechRecognizer"
    @Published private(set) var confidence: Double?
    @Published private(set) var wordCount: Int = 0

    private let audioSessionManager: AudioSessionManager
    private let activityManager = TranscriptionActivityManager.shared
    private let sharedState = SharedTranscriptionState.shared

    private var appleTranscriber: iOSLiveTranscriber?
    private var deepgramTranscriber: DeepgramLiveTranscriber?
    private var elevenLabsTranscriber: ElevenLabsLiveTranscriber?
    private var openAITranscriber: OpenAIRealtimeLiveTranscriber?
    private var startTime: Date?

    init() {
        self.audioSessionManager = AudioSessionManager()
    }

    var modelDisplayName: String {
        if currentModel.hasPrefix("deepgram") {
            return "Deepgram"
        }
        if currentModel.hasPrefix("elevenlabs") {
            return "ElevenLabs"
        }
        if currentModel.hasPrefix("openai") {
            return "OpenAI gpt-realtime-whisper"
        }
        return "Apple Speech"
    }

    private var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    // swiftlint:disable:next function_body_length
    func start() async throws {
        let settings = AppSettings.shared
        currentModel = settings.selectedModel
        partialText = ""
        wordCount = 0
        startTime = Date()
        sharedState.clear()

        // Fallback to Apple Speech if Deepgram selected but no API key
        if currentModel.hasPrefix("deepgram") && !settings.hasDeepgramKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Fallback to Apple Speech if ElevenLabs selected but no API key
        if currentModel.hasPrefix("elevenlabs") && !settings.hasElevenLabsKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Fallback to Apple Speech if OpenAI selected but no API key
        if currentModel.hasPrefix("openai") && !settings.hasOpenAIKey {
            currentModel = "apple/local/SFSpeechRecognizer"
        }

        // Start Live Activity (if enabled)
        if settings.liveActivitiesEnabled {
            activityManager.startActivity(provider: modelDisplayName)
        }

        if currentModel.hasPrefix("deepgram") {
            // Use Deepgram
            let transcriber = DeepgramLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: settings.deepgramAPIKey)
            transcriber.model = currentModel.replacingOccurrences(of: "deepgram/", with: "")

            transcriber.onPartialResult = { [weak self] text, isFinal in
                self?.handlePartialResult(text: self?.deepgramTranscriber?.partialText ?? text, isFinal: isFinal)
            }
            transcriber.onError = { [weak self] error in
                self?.handleError(error)
            }

            deepgramTranscriber = transcriber
            appleTranscriber = nil
            elevenLabsTranscriber = nil

            try await transcriber.start()
            isRunning = true
        } else if currentModel.hasPrefix("elevenlabs") {
            // Use ElevenLabs
            let transcriber = ElevenLabsLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: settings.elevenLabsAPIKey)
            transcriber.modelID = currentModel.replacingOccurrences(of: "elevenlabs/", with: "")

            transcriber.onPartialResult = { [weak self] text, isFinal in
                self?.handlePartialResult(text: self?.elevenLabsTranscriber?.partialText ?? text, isFinal: isFinal)
            }
            transcriber.onError = { [weak self] error in
                self?.handleError(error)
            }

            elevenLabsTranscriber = transcriber
            deepgramTranscriber = nil
            appleTranscriber = nil

            try await transcriber.start()
            isRunning = true
        } else if currentModel.hasPrefix("openai") {
            // Use OpenAI Realtime
            let transcriber = OpenAIRealtimeLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: settings.openAIAPIKey)
            transcriber.modelID = currentModel.replacingOccurrences(of: "openai/", with: "")

            transcriber.onPartialResult = { [weak self] text, isFinal in
                self?.handlePartialResult(text: self?.openAITranscriber?.partialText ?? text, isFinal: isFinal)
            }
            transcriber.onError = { [weak self] error in
                self?.handleError(error)
            }

            openAITranscriber = transcriber
            elevenLabsTranscriber = nil
            deepgramTranscriber = nil
            appleTranscriber = nil

            try await transcriber.start()
            isRunning = true
        } else {
            // Use Apple Speech
            let transcriber = iOSLiveTranscriber(audioSessionManager: audioSessionManager)

            transcriber.onPartialResult = { [weak self] text, isFinal in
                self?.handlePartialResult(text: self?.appleTranscriber?.partialText ?? text, isFinal: isFinal)
                self?.confidence = self?.appleTranscriber?.confidence
            }
            transcriber.onError = { [weak self] error in
                self?.handleError(error)
            }

            appleTranscriber = transcriber
            deepgramTranscriber = nil
            elevenLabsTranscriber = nil
            openAITranscriber = nil

            try await transcriber.start()
            isRunning = true
        }
    }

    private func handlePartialResult(text: String, isFinal: Bool) {
        partialText = text
        wordCount = text.split(separator: " ").count

        // Update shared state for copy actions
        sharedState.updateTranscript(text)

        // Update Live Activity (if enabled)
        if AppSettings.shared.liveActivitiesEnabled {
            activityManager.updateActivity(
                status: .listening,
                lastSnippet: text,
                wordCount: wordCount,
                duration: elapsedSeconds
            )
        }
    }

    private func handleError(_ error: Error) {
        self.error = error
        if AppSettings.shared.liveActivitiesEnabled {
            activityManager.reportError(error.localizedDescription)
        }
    }

    func stop() async -> TranscriptionResult {
        isRunning = false
        let duration = elapsedSeconds

        // Complete Live Activity (if enabled)
        if AppSettings.shared.liveActivitiesEnabled {
            activityManager.completeActivity(finalWordCount: wordCount, duration: duration)
        }

        if let deepgram = deepgramTranscriber {
            let result = await deepgram.stop()
            deepgramTranscriber = nil
            return finishStop(with: result)
        } else if let elevenlabs = elevenLabsTranscriber {
            let result = await elevenlabs.stop()
            elevenLabsTranscriber = nil
            return finishStop(with: result)
        } else if let openai = openAITranscriber {
            let result = await openai.stop()
            openAITranscriber = nil
            return finishStop(with: result)
        } else if let apple = appleTranscriber {
            let result = await apple.stop()
            appleTranscriber = nil
            return finishStop(with: result)
        }

        startTime = nil
        return TranscriptionResult(
            text: partialText,
            segments: [],
            confidence: nil,
            duration: TimeInterval(duration),
            modelIdentifier: currentModel,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    private func finishStop(with result: TranscriptionResult) -> TranscriptionResult {
        iOSHistoryManager.shared.recordTranscription(
            text: result.text,
            model: currentModel,
            duration: result.duration
        )
        startTime = nil
        return result
    }

    func cancel() {
        deepgramTranscriber?.cancel()
        elevenLabsTranscriber?.cancel()
        openAITranscriber?.cancel()
        appleTranscriber?.cancel()
        deepgramTranscriber = nil
        elevenLabsTranscriber = nil
        openAITranscriber = nil
        appleTranscriber = nil
        isRunning = false
        startTime = nil
        if AppSettings.shared.liveActivitiesEnabled {
            activityManager.endActivity()
        }
        sharedState.clear()
    }
}

// swiftlint:disable:next type_body_length
public struct ContentView: View {
    @StateObject private var coordinator = TranscriberCoordinator()
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var copied = false
    @State private var showingPostProcessing = false
    @State private var displayText = ""  // Text shown in UI (may be post-processed)
    @Namespace private var controlsNamespace

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                // Content layer - transcript display (base plane, no glass)
                VStack {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if displayText.isEmpty && coordinator.partialText.isEmpty {
                                    Text("Tap the microphone to start transcription")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.top, 100)
                                } else {
                                    Text(displayText.isEmpty ? coordinator.partialText : displayText)
                                        .font(.title3)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding()
                            .id("transcript")
                        }
                        .onChange(of: coordinator.partialText) { _, _ in
                            // Update display text when recording (unless we have post-processed text)
                            if coordinator.isRunning {
                                displayText = ""  // Clear post-processed text during new recording
                            }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("transcript", anchor: .bottom)
                            }
                        }
                    }

                    Spacer(minLength: 120) // Space for floating controls
                }

                // Controls layer - floating glass controls
                VStack {
                    Spacer()

                    // Floating control cluster with Liquid Glass
                    floatingControls
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                }
            }
            .navigationTitle("Just Speak to It")
            .toolbar {
                // Status indicator in toolbar (system handles glass)
                if coordinator.isRunning {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                            if let confidence = coordinator.confidence {
                                Text("\(Int(confidence * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        NavigationLink {
                            HistoryView()
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .accessibilityLabel("History")

                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gear")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
            .onChange(of: coordinator.error?.localizedDescription) { _, newError in
                if let error = newError {
                    errorMessage = error
                    showingError = true
                }
            }
            .task {
                // Auto-start recording if enabled
                if AppSettings.shared.autoStartRecording && !coordinator.isRunning {
                    do {
                        try await coordinator.start()
                    } catch {
                        errorMessage = error.localizedDescription
                        showingError = true
                    }
                }
            }
            .sheet(isPresented: $showingPostProcessing) {
                PostProcessingView(initialText: currentText) { processedResult in
                    displayText = processedResult
                }
            }
        }
    }

    // MARK: - Floating Controls with Glass Effect

    @ViewBuilder
    private var floatingControls: some View {
        #if compiler(>=6.1) && canImport(SwiftUI, _version: 7.0)
        if #available(iOS 26.0, *) {
            floatingControlsGlass
        } else {
            floatingControlsFallback
        }
        #else
        floatingControlsFallback
        #endif
    }

    #if compiler(>=6.1) && canImport(SwiftUI, _version: 7.0)
    @available(iOS 26.0, *)
    @ViewBuilder
    private var floatingControlsGlass: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                // Primary action - Start/Stop
                Button {
                    Task {
                        await toggleRecording()
                    }
                } label: {
                    Image(systemName: coordinator.isRunning ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28))
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.glassProminent)
                .tint(coordinator.isRunning ? .red : .brandAccent)
                .clipShape(Circle())
                .accessibilityLabel(coordinator.isRunning ? "Stop recording" : "Start recording")

                // Secondary actions (only visible when there's text and not recording)
                if hasTextToShow && !coordinator.isRunning {
                    // Polish/Post-process button
                    Button {
                        showingPostProcessing = true
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 20))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.glass)
                    .tint(.purple)
                    .clipShape(Circle())
                    .accessibilityLabel("Polish transcript")
                    .transition(.scale.combined(with: .opacity))

                    // Copy button
                    Button {
                        copyToClipboard()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 20))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.glass)
                    .tint(.brandAccentWarm)
                    .clipShape(Circle())
                    .accessibilityLabel(copied ? "Copied to clipboard" : "Copy transcript")
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasTextToShow)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: coordinator.isRunning)
    }
    #endif

    @ViewBuilder
    private var floatingControlsFallback: some View {
        HStack(spacing: 16) {
            // Primary action - Start/Stop
            Button {
                Task {
                    await toggleRecording()
                }
            } label: {
                Image(systemName: coordinator.isRunning ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(coordinator.isRunning ? .red : .accentColor)
            .clipShape(Circle())
            .accessibilityLabel(coordinator.isRunning ? "Stop recording" : "Start recording")

            // Secondary actions (only visible when there's text and not recording)
            if hasTextToShow && !coordinator.isRunning {
                // Polish/Post-process button
                Button {
                    showingPostProcessing = true
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 20))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .clipShape(Circle())
                .accessibilityLabel("Polish transcript")
                .transition(.scale.combined(with: .opacity))

                // Copy button
                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 20))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .accessibilityLabel(copied ? "Copied to clipboard" : "Copy transcript")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasTextToShow)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: coordinator.isRunning)
    }

    // MARK: - Computed Properties

    private var hasTextToShow: Bool {
        !displayText.isEmpty || !coordinator.partialText.isEmpty
    }

    private var currentText: String {
        displayText.isEmpty ? coordinator.partialText : displayText
    }

    // MARK: - Actions

    private func toggleRecording() async {
        if coordinator.isRunning {
            let result = await coordinator.stop()
            print("[ContentView] Final result: \(result.text.count) chars, duration: \(result.duration)s")

            // Auto post-process if enabled
            if settings.autoPostProcess && settings.hasOpenRouterKey && !result.text.isEmpty {
                showingPostProcessing = true
            }
        } else {
            // Clear previous text when starting new recording
            displayText = ""
            do {
                try await coordinator.start()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = currentText
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

#Preview {
    ContentView()
}
#endif
// swiftlint:enable file_length
