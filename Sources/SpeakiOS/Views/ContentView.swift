#if os(iOS)
import SwiftUI
import SpeakCore

// swiftlint:disable file_length
/// Unified transcriber that switches between Apple Speech and Deepgram.
/// Integrates with Live Activity for lock screen presence.
@MainActor
// swiftlint:disable:next type_body_length
final class TranscriberCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var partialText = ""
    @Published private(set) var error: Error?
    @Published private(set) var currentModel: String = AppleLocalModels.preferredSpeechModelID
    @Published private(set) var confidence: Double?
    @Published private(set) var wordCount: Int = 0

    private let audioSessionManager: AudioSessionManager
    private let activityManager = TranscriptionActivityManager.shared
    private let sharedState = SharedTranscriptionState.shared

    private var appleTranscriber: iOSLiveTranscriber?
    private var deepgramTranscriber: DeepgramLiveTranscriber?
    private var elevenLabsTranscriber: ElevenLabsLiveTranscriber?
    private var openAITranscriber: OpenAIRealtimeLiveTranscriber?
    private var sharedTranscriber: SharedClientLiveTranscriber?
    private var batchTranscriber: IOSBatchTranscriber?
    private var startTime: Date?

    init() {
        self.audioSessionManager = AudioSessionManager()
    }

    var modelDisplayName: String {
        if batchTranscriber != nil {
            return ModelCatalog.friendlyName(for: currentModel)
        }
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
        currentModel = settings.transcriptionMode == .batch
            ? settings.batchTranscriptionModel
            : settings.selectedModel
        partialText = ""
        wordCount = 0
        startTime = Date()
        sharedState.clear()

        if settings.transcriptionMode == .streaming {
            let route = LiveTranscriptionRouting.route(for: currentModel)
            currentModel = LiveTranscriptionRouting.resolvedModelID(
                for: currentModel,
                apiKey: route.map { settings.liveAPIKey(for: $0) }
            )
        }

        // Start Live Activity (if enabled)
        if settings.liveActivitiesEnabled {
            activityManager.startActivity(provider: modelDisplayName)
        }

        #if DEBUG && targetEnvironment(simulator)
        if let transcript = sharedState.simulatorValidationTranscript {
            handlePartialResult(text: transcript, isFinal: true)
            markRecordingStarted()
            return
        }
        #endif

        if settings.transcriptionMode == .batch {
            let transcriber = IOSBatchTranscriber(
                audioSessionManager: audioSessionManager,
                model: currentModel,
                apiKey: settings.batchAPIKey
            )
            batchTranscriber = transcriber
            appleTranscriber = nil
            deepgramTranscriber = nil
            elevenLabsTranscriber = nil
            openAITranscriber = nil
            sharedTranscriber = nil
            try await transcriber.start()
            markRecordingStarted()
        } else if currentModel.hasPrefix("deepgram") {
            // Use Deepgram
            let transcriber = DeepgramLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: settings.deepgramAPIKey)
            transcriber.model = LiveTranscriptionRouting.route(for: currentModel)?.apiModelName
                ?? currentModel.replacingOccurrences(of: "deepgram/", with: "")

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
            markRecordingStarted()
        } else if currentModel.hasPrefix("elevenlabs") {
            // Use ElevenLabs
            let transcriber = ElevenLabsLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: settings.elevenLabsAPIKey)
            transcriber.modelID = LiveTranscriptionRouting.route(for: currentModel)?.apiModelName
                ?? currentModel.replacingOccurrences(of: "elevenlabs/", with: "")

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
            markRecordingStarted()
        } else if currentModel.hasPrefix("openai") {
            // Use OpenAI Realtime
            let transcriber = OpenAIRealtimeLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: settings.openAIAPIKey)
            transcriber.modelID = LiveTranscriptionRouting.route(for: currentModel)?.apiModelName
                ?? currentModel.replacingOccurrences(of: "openai/", with: "")

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
            markRecordingStarted()
        } else if let route = LiveTranscriptionRouting.route(for: currentModel),
                  route.provider.isSupportedOnIOS {
            // Generic shared-client path (Cartesia, and future ported providers).
            let transcriber = SharedClientLiveTranscriber(
                route: route,
                apiKey: settings.liveAPIKey(for: route),
                audioSessionManager: audioSessionManager
            )
            transcriber.onPartialResult = { [weak self] text, isFinal in
                self?.handlePartialResult(text: self?.sharedTranscriber?.partialText ?? text, isFinal: isFinal)
            }
            transcriber.onError = { [weak self] error in
                self?.handleError(error)
            }

            sharedTranscriber = transcriber
            deepgramTranscriber = nil
            elevenLabsTranscriber = nil
            openAITranscriber = nil
            appleTranscriber = nil

            try await transcriber.start()
            markRecordingStarted()
        } else {
            // Use Apple Speech
            let transcriber = iOSLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.modelID = currentModel

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
            sharedTranscriber = nil

            try await transcriber.start()
            markRecordingStarted()
        }
    }

    private func markRecordingStarted() {
        isRunning = true
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime
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

    // swiftlint:disable:next function_body_length
    func stop() async -> TranscriptionResult {
        isRunning = false
        sharedState.clearRecordingState()
        let duration = elapsedSeconds

        // Streaming results can complete immediately. Batch recordings remain
        // in a processing state until the upload returns.
        if AppSettings.shared.liveActivitiesEnabled {
            if batchTranscriber != nil {
                activityManager.updateActivity(
                    status: .processing,
                    lastSnippet: "Transcribing recording…",
                    wordCount: 0,
                    duration: duration
                )
            } else {
                activityManager.completeActivity(finalWordCount: wordCount, duration: duration)
            }
        }

        if let batch = batchTranscriber {
            batchTranscriber = nil
            do {
                let result = try await batch.stop(language: Locale.current.identifier)
                partialText = result.text
                wordCount = result.text.split(whereSeparator: \.isWhitespace).count
                if AppSettings.shared.liveActivitiesEnabled {
                    activityManager.completeActivity(finalWordCount: wordCount, duration: duration)
                }
                return finishStop(with: result)
            } catch {
                handleError(error)
            }
        } else if let deepgram = deepgramTranscriber {
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
        } else if let shared = sharedTranscriber {
            let result = await shared.stop()
            sharedTranscriber = nil
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
        sharedTranscriber?.cancel()
        batchTranscriber?.cancel()
        deepgramTranscriber = nil
        elevenLabsTranscriber = nil
        openAITranscriber = nil
        appleTranscriber = nil
        sharedTranscriber = nil
        batchTranscriber = nil
        isRunning = false
        startTime = nil
        if AppSettings.shared.liveActivitiesEnabled {
            activityManager.endActivity()
        }
        sharedState.clear()
        sharedState.clearRecordingState()
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

    /// The headless Action Button / Siri / Shortcuts recorder. Observed so the
    /// app can surface the most recent background session as the current view and
    /// badge History when a recording landed while the app was away.
    @ObservedObject private var backgroundService = TranscriptionRecordingService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHistoryBadge = false
    /// Completion time of the background transcript we last surfaced, so we only
    /// surface a given session once and never clobber the user's in-app edits.
    @State private var lastSurfacedAt: Date?

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                // Content layer - transcript display (base plane, no glass)
                VStack {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(
                                alignment: .leading,
                                spacing: settings.visualDensity == .compact ? 8 : 12
                            ) {
                                if currentText.isEmpty {
                                    Text(backgroundService.isRunning
                                         ? "Recording via Action Button…"
                                         : "Tap the microphone to start transcription")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.top, 100)
                                } else {
                                    Text(currentText)
                                        .font(.title3)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(settings.visualDensity == .compact ? 12 : 16)
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
                        .onChange(of: backgroundService.partialText) { _, _ in
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
                if coordinator.isRunning || backgroundService.isRunning {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                            if coordinator.isRunning, let confidence = coordinator.confidence {
                                Text("\(Int(confidence * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            backgroundService.isRunning ? "Recording via Action Button" : "Recording"
                        )
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        NavigationLink {
                            HistoryView()
                                .onAppear { markHistorySeen() }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .overlay(alignment: .topTrailing) {
                                    if showHistoryBadge {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 8, height: 8)
                                            .offset(x: 5, y: -4)
                                    }
                                }
                        }
                        .accessibilityLabel(showHistoryBadge ? "History, new background recording" : "History")

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
            .onAppear { refreshBackgroundState() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshBackgroundState() }
            }
            .onChange(of: backgroundService.isRunning) { wasRunning, isRunning in
                // A live background session just finished — surface its result
                // instead of leaving the screen blank.
                if wasRunning && !isRunning { refreshBackgroundState() }
            }
            .sheet(isPresented: $showingPostProcessing) {
                PostProcessingView(initialText: currentText) { processedResult in
                    displayText = processedResult
                }
            }
        }
        .environment(\.appVisualDensity, settings.visualDensity)
        .environment(\.defaultMinListRowHeight, settings.visualDensity.minimumListRowHeight)
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
                    Image(systemName: isAnyRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28))
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.glassProminent)
                .tint(isAnyRecording ? .red : .brandAccent)
                .clipShape(Circle())
                .accessibilityLabel(isAnyRecording ? "Stop recording" : "Start recording")

                // Secondary actions (only visible when there's text and not recording)
                if hasTextToShow && !isAnyRecording {
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
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: backgroundService.isRunning)
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
                Image(systemName: isAnyRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(isAnyRecording ? .red : .accentColor)
            .clipShape(Circle())
            .accessibilityLabel(isAnyRecording ? "Stop recording" : "Start recording")

            // Secondary actions (only visible when there's text and not recording)
            if hasTextToShow && !isAnyRecording {
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
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: backgroundService.isRunning)
    }

    // MARK: - Computed Properties

    private var hasTextToShow: Bool {
        !currentText.isEmpty
    }

    private var isAnyRecording: Bool {
        coordinator.isRunning || backgroundService.isRunning
    }

    private var currentText: String {
        // A live background (Action Button) session takes precedence so opening
        // the app mid-recording shows it live.
        if backgroundService.isRunning {
            return backgroundService.partialText
        }
        return displayText.isEmpty ? coordinator.partialText : displayText
    }

    // MARK: - Background session surfacing

    /// Surfaces the most recent background (Action Button / Siri / Shortcuts)
    /// transcript as the current view and updates the History badge. Called on
    /// appear and whenever the app returns to the foreground so a headless
    /// recording is never lost behind a stale in-app transcript.
    private func refreshBackgroundState() {
        let shared = SharedTranscriptionState.shared
        showHistoryBadge = shared.hasUnseenBackgroundTranscript

        guard shared.hasUnseenBackgroundTranscript,
              !coordinator.isRunning,
              !backgroundService.isRunning,
              let text = shared.lastCompletedTranscript,
              !text.isEmpty else {
            return
        }

        // Surface a given background transcript only once. Comparing completion
        // timestamps stops repeated foreground cycles from overwriting the
        // user's in-app edits with the same background result.
        let completedAt = shared.lastCompletedAt
        if let surfaced = lastSurfacedAt, let completedAt, completedAt <= surfaced {
            return
        }
        displayText = text
        lastSurfacedAt = completedAt ?? Date()
    }

    /// Clears the History badge once the user opens History.
    private func markHistorySeen() {
        SharedTranscriptionState.shared.markBackgroundTranscriptSeen()
        showHistoryBadge = false
    }

    // MARK: - Actions

    private func toggleRecording() async {
        if backgroundService.isRunning {
            let result = await backgroundService.stopRecording(
                destination: settings.hardwareTriggerDestination
            )
            displayText = result.text
        } else if coordinator.isRunning {
            let result = await coordinator.stop()
            print("[ContentView] Final result: \(result.text.count) chars, duration: \(result.duration)s")

            // Auto post-process if enabled
            if settings.autoPostProcess && settings.hasOpenRouterKey && !result.text.isEmpty {
                showingPostProcessing = true
            }
        } else {
            // A background (Action Button) session owns the mic; don't start a
            // second, conflicting in-app recording. The user stops the background
            // one the same way they started it.
            guard !backgroundService.isRunning else {
                errorMessage = "A background recording is already in progress. "
                    + "Use the Action Button to stop it."
                showingError = true
                return
            }

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
