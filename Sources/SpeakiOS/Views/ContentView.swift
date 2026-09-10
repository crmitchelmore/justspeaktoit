#if os(iOS)
import AVFoundation
import SwiftUI
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "ContentView")

// swiftlint:disable file_length
/// Foreground recording coordinator backed by the shared iOS transcription factory.
/// Integrates with Live Activity for lock screen presence.
@MainActor
final class TranscriberCoordinator: ObservableObject {
    private enum LifecycleError: LocalizedError {
        case sessionFinalising

        var errorDescription: String? {
            "The previous transcription is still finalising."
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var partialText = ""
    @Published private(set) var error: Error?
    @Published private(set) var currentModel: String = AppleLocalModels.preferredSpeechModelID
    @Published private(set) var confidence: Double?
    @Published private(set) var wordCount: Int = 0

    let audioSessionManager: AudioSessionManager
    private let activityManager = TranscriptionActivityManager.shared
    private let sharedState = SharedTranscriptionState.shared

    private var transcriptionSession: IOSTranscriptionSession?
    private var stoppingSession: IOSTranscriptionSession?
    private var stopWasCancelled = false
    var onCaptureDisruption: (() async -> Void)?
    /// Truthful capture presentation (issue #983): startup stays visibly
    /// "preparing" until this run has both started its backend and observed a
    /// buffer from its own live input tap.
    private var presentation = CapturePresentationGate()
    /// Local run-scoped startup timing (issue #972). Measurement only: it adds
    /// no network call, no vendor reporting and no behaviour change.
    private var diagnostics = StartupDiagnostics()
    private var presentationRunID: UUID?
    /// Raised when this coordinator's capture presentation changes, so an
    /// owner presenting on its behalf (hands-free) can re-publish.
    var onCapturePresentationChanged: (() -> Void)?

    /// Whether active-capture presentation may be shown for the current run.
    var isPresentingCapture: Bool { presentation.isPresentingCapture }
    private var startTime: Date?
    /// Last time the App Group shared state was written for a partial result.
    private var lastSharedStateWriteAt: Date = .distantPast
    private static let sharedStateWriteInterval: TimeInterval = 1.0

    init() {
        self.audioSessionManager = AudioSessionManager()
    }

    var modelDisplayName: String {
        ModelCatalog.transcriptionDisplayName(
            for: currentModel,
            isBatch: transcriptionSession?.isBatch
                ?? (AppSettings.shared.transcriptionMode == .batch)
        )
    }

    private var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    /// Exclusive ownership of provider startup, so a second call while the
    /// first is still awaiting `session.start` cannot create a second session
    /// and leave the earlier one capturing (#943). This is the same guard the
    /// transcribers use; the coordinator does not invent its own.
    private let startup = RecordingStartupOperation()

    /// True while a start is in flight. UI that toggles recording uses this to
    /// stay on one action until startup settles.
    var isStartingRecording: Bool { startup.isStarting }

    /// - Parameter entry: the earliest app-code entry the caller observed.
    ///   Callers with no earlier observation pass `nil` and the coordinator
    ///   times its own entry (issue #972).
    func start(
        preRollBuffers: [AVAudioPCMBuffer] = [],
        analyzerFallbackAllowed: Bool = true,
        entry: StartupEntry? = nil
    ) async throws {
        guard stoppingSession == nil else { throw LifecycleError.sessionFinalising }
        guard !isRunning, !startup.isStarting else { return }
        try await startup.run {
            try await self.performStart(
                preRollBuffers: preRollBuffers,
                analyzerFallbackAllowed: analyzerFallbackAllowed,
                entry: entry
            )
        }
    }

    // swiftlint:disable:next function_body_length
    private func performStart(
        preRollBuffers: [AVAudioPCMBuffer],
        analyzerFallbackAllowed: Bool,
        entry: StartupEntry?
    ) async throws {
        let runID = beginRun(entry: entry)
        let settings = AppSettings.shared
        // Wait for the initial keychain load so auto-start on a cold launch
        // doesn't read empty API keys and fall back to Apple Speech.
        await settings.ensureKeysLoaded()
        diagnostics.note(.stage(.credentialsReady), run: runID)
        error = nil
        currentModel = settings.transcriptionMode == .batch
            ? settings.batchTranscriptionModel
            : settings.selectedModel
        partialText = ""
        wordCount = 0
        lastSharedStateWriteAt = .distantPast
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
            activityManager.startActivity(provider: modelDisplayName, initialStatus: .arming)
        }

        #if DEBUG && targetEnvironment(simulator)
        if let transcript = sharedState.simulatorValidationTranscript {
            // A synthetic transcript is not observed microphone input, but this
            // DEBUG-only simulator stub has no input tap at all. Resolve the
            // gate explicitly so the harness never sits in preparation.
            presentation.noteBackendStarted(run: runID)
            notePresentation(presentation.noteInputObserved(run: runID))
            noteSimulatorStubStartup(runID: runID)
            handlePartialResult(text: transcript, isFinal: true)
            markRecordingStarted()
            return
        }
        #endif

        let mode: IOSTranscriptionSession.Mode = settings.transcriptionMode == .batch
            ? .batch(retainRecording: true)
            : .streaming
        let session = try IOSTranscriptionSession(
            modelID: currentModel,
            mode: mode,
            language: settings.preferredModelLanguage,
            audioSessionManager: audioSessionManager,
            batchAPIKey: settings.batchAPIKey,
            liveAPIKey: settings.liveAPIKey(for:),
            transcriptionKeywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords)
        )
        session.onPartialResult = { [weak self, weak session] text, isFinal in
            self?.noteFirstLivePartial(text: text, isFinal: isFinal, runID: runID)
            self?.handlePartialResult(text: text, isFinal: isFinal)
            self?.confidence = session?.confidence
        }
        session.onError = { [weak self, weak session] error in
            guard let self, let session,
                  self.transcriptionSession === session || self.stoppingSession === session else { return }
            self.handleError(error)
            guard case iOSTranscriptionError.microphoneChanged = error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.transcriptionSession === session, self.isRunning else { return }
                if let onCaptureDisruption = self.onCaptureDisruption {
                    await onCaptureDisruption()
                } else {
                    _ = await self.stop()
                }
            }
        }
        bindFirstInput(session: session, runID: runID)
        bindStartupDiagnostics(session: session, runID: runID)
        transcriptionSession = session
        do {
            try await session.start(
                preRollBuffers: preRollBuffers,
                analyzerFallbackAllowed: analyzerFallbackAllowed
            )
            diagnostics.note(.stage(.sessionStarted), run: runID)
        } catch {
            session.cancel()
            transcriptionSession = nil
            startTime = nil
            finishStartupDiagnostics(runID: runID, error: error)
            finishPresentation()
            if settings.liveActivitiesEnabled {
                activityManager.endActivity()
            }
            throw error
        }
        markRecordingStarted()
        // The tap can deliver before `start()` returns, so this may be the
        // second half of the pair rather than the first.
        notePresentation(presentation.noteBackendStarted(run: runID))
        diagnostics.finish(.started, run: runID)
    }

    private func markRecordingStarted() {
        isRunning = true
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime
    }

    private func handlePartialResult(text: String, isFinal: Bool) {
        partialText = text

        // App Group writes and word counting are O(n) per partial; throttle
        // them to ~1/s (matching the Live Activity manager's own throttle).
        // The full transcript is committed once more at stop.
        let now = Date()
        if now.timeIntervalSince(lastSharedStateWriteAt) >= Self.sharedStateWriteInterval {
            lastSharedStateWriteAt = now
            wordCount = text.split(separator: " ").count
            // Update shared state for copy actions
            sharedState.updateTranscript(text)
        }

        publishTranscriptActivity(text: text)
    }

    func stop(rearmHandsFree: Bool = false) async -> TranscriptionResult {
        isRunning = false
        finishPresentation()
        sharedState.clearRecordingState()
        let duration = elapsedSeconds

        if AppSettings.shared.liveActivitiesEnabled {
            activityManager.updateActivity(
                status: .finalising,
                lastSnippet: "Finalising transcript…",
                wordCount: wordCount,
                duration: duration
            )
        }

        if let session = transcriptionSession,
           let result = await stop(session: session, duration: duration, rearmHandsFree: rearmHandsFree) {
            return result
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

    private func stop(
        session: IOSTranscriptionSession,
        duration: Int,
        rearmHandsFree: Bool
    ) async -> TranscriptionResult? {
        transcriptionSession = nil
        stoppingSession = session
        stopWasCancelled = false
        defer {
            if stoppingSession === session {
                stoppingSession = nil
            }
        }
        do {
            let drained = try await session.stop()
            let result = drained.replacingText(TranscriptionRecordingService.bestTranscript(
                candidates: [drained.text, partialText], fallback: ""
            ))
            guard !Task.isCancelled, !stopWasCancelled, stoppingSession === session else {
                startTime = nil
                return result
            }
            partialText = result.text
            wordCount = result.text.split(whereSeparator: \.isWhitespace).count
            if AppSettings.shared.liveActivitiesEnabled {
                activityManager.completeActivity(
                    finalWordCount: wordCount,
                    duration: duration,
                    keepPrimed: rearmHandsFree,
                    primedMessage: "Hands-free armed",
                    primedStatus: rearmHandsFree ? .armed : .idle,
                    completionOutcome: .unconfirmed(transcript: result.text),
                    resultPreview: TranscriptionResultRow.preview(for: result.text)
                )
            }
            return finishStop(with: result)
        } catch {
            handleError(error)
            return nil
        }
    }

    private func finishStop(with result: TranscriptionResult) -> TranscriptionResult {
        // Live shared-state writes are throttled; commit the final transcript
        // once so the copy intents always see the complete text.
        sharedState.updateTranscript(result.text)
        // Onboarding progress is only ever earned by a transcript that really
        // arrived; a blank one is ignored by the policy.
        CaptureOnboardingStore.shared.recordDictation(trigger: .inApp, transcript: result.text)
        iOSHistoryManager.shared.recordTranscription(
            text: result.text,
            model: currentModel,
            duration: result.duration
        )
        startTime = nil
        return result
    }

    func cancel() {
        transcriptionSession?.cancel()
        stopWasCancelled = stoppingSession != nil
        stoppingSession?.cancel()
        transcriptionSession = nil
        // A stopping session retains ownership until its suspended drain returns.
        isRunning = false
        finishPresentation()
        startTime = nil
        if AppSettings.shared.liveActivitiesEnabled {
            activityManager.endActivity()
        }
        sharedState.clear()
        sharedState.clearRecordingState()
    }
}

// MARK: - Truthful capture presentation (issue #983)

private extension TranscriberCoordinator {
    /// Routes this run's own first live buffer into the presentation gate.
    func bindFirstInput(session: IOSTranscriptionSession, runID: UUID) {
        session.onFirstInputBuffer = { [weak self, weak session] in
            guard let self, let session, self.transcriptionSession === session else { return }
            self.notePresentation(self.presentation.noteInputObserved(run: runID))
        }
    }

    /// Publishes the one arming → recording transition, and only that one.
    func notePresentation(_ promoted: Bool) {
        guard promoted else { return }
        if AppSettings.shared.liveActivitiesEnabled {
            activityManager.updateActivity(
                status: .recording,
                lastSnippet: partialText,
                wordCount: wordCount,
                duration: elapsedSeconds
            )
        }
        onCapturePresentationChanged?()
    }

    /// Ends the run's presentation: stop, cancel, or a failed start. A run that
    /// never saw input therefore resolves to a terminal state, not to
    /// permanent preparation.
    func finishPresentation() {
        guard presentationRunID != nil else { return }
        presentationRunID = nil
        presentation.finish()
        // A late partial cannot report against a run that is over.
        diagnostics.retire()
        onCapturePresentationChanged?()
    }

}

/// Live Activity presentation for the foreground coordinator. In an extension
/// so the coordinator itself stays inside the type-length limit.
extension TranscriberCoordinator {
    /// Publishes a mid-session failure and mirrors it into the Live Activity.
    func handleError(_ error: Error) {
        self.error = error
        if AppSettings.shared.liveActivitiesEnabled {
            activityManager.reportError(error.localizedDescription)
        }
    }

    /// Presentation only: the transcript is delivered either way. A partial can
    /// arrive from pre-roll before this run has seen its own input, and it must
    /// not announce active capture.
    func publishTranscriptActivity(text: String) {
        guard AppSettings.shared.liveActivitiesEnabled else { return }
        guard presentation.isPresentingCapture else {
            activityManager.updateActivity(
                status: .arming,
                lastSnippet: CapturePresentationGate.preparingMessage,
                wordCount: 0,
                duration: 0
            )
            return
        }
        activityManager.updateActivity(
            status: .recording,
            lastSnippet: text,
            wordCount: wordCount,
            duration: elapsedSeconds
        )
    }
}

/// Local run-scoped startup measurement for this coordinator (issue #972).
/// Measurement only — nothing here changes capture, ordering or delivery.
private extension TranscriberCoordinator {
    /// Opens a run: one identity shared by the presentation gate and the
    /// startup measurement, so neither can attribute work to the other's run.
    func beginRun(entry: StartupEntry?) -> UUID {
        let runID = UUID()
        presentationRunID = runID
        presentation.begin(run: runID)
        diagnostics.begin(run: runID, entry: entry, localOrigin: .coordinator)
        return runID
    }

    /// Wires this run to the session's existing observation boundary, and
    /// labels the backend when routing already settled it.
    func bindStartupDiagnostics(session: IOSTranscriptionSession, runID: UUID) {
        session.onStartupObservation = { [weak self] observation in
            self?.diagnostics.note(observation, run: runID)
        }
        if let backend = session.resolution.resolvedStartupBackend {
            diagnostics.note(.backend(backend), run: runID)
        }
    }

    /// The measured boundary is the first *live* partial: a final result is a
    /// delivery, not evidence that streaming began.
    func noteFirstLivePartial(text: String, isFinal: Bool, runID: UUID) {
        guard !isFinal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        diagnostics.noteFirstPartial(run: runID)
    }

    /// A start that stopped short still reports what it did reach; the stages
    /// it never crossed stay absent rather than becoming zeroes.
    func finishStartupDiagnostics(runID: UUID, error: Error) {
        diagnostics.finish(
            (error is CancellationError || Task.isCancelled) ? .cancelled : .failed,
            run: runID
        )
    }

    /// Explicitly synthetic: the DEBUG simulator stub has no audio session, no
    /// engine and no measured engine start.
    func noteSimulatorStubStartup(runID: UUID) {
        diagnostics.note(.backend(.simulatorStub), run: runID)
        diagnostics.finish(.started, run: runID)
    }
}

// swiftlint:disable:next type_body_length
public struct ContentView: View {
    @StateObject private var recovery = CaptureRecoveryCoordinator.shared
    @State private var showingRecoveryPrompt = false
    @StateObject private var coordinator: TranscriberCoordinator
    @StateObject private var handsFree: IOSHandsFreeDictationCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingError = false
    @State private var errorMessage = ""
    /// The background session failure already alerted on, so the change
    /// observer and the on-appear read cannot show it twice.
    @State private var presentedSessionError: String?
    @State private var copied = false
    @State private var showingPostProcessing = false
    @State private var displayText = ""  // Text shown in UI (may be post-processed)
    @Namespace private var controlsNamespace

    /// The headless Action Button / Siri / Shortcuts recorder. Observed so the
    /// app can surface the most recent background session as the current view and
    /// badge History when a recording landed while the app was away.
    @ObservedObject private var backgroundService = TranscriptionRecordingService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showHistoryBadge = false
    /// Guided first run and the progressive per-trigger cards. Every decision
    /// here comes from `CaptureOnboardingPolicy`; this layer only renders it.
    @ObservedObject private var onboarding = CaptureOnboardingStore.shared
    @State private var showingFirstRun = false
    /// Recordings handed over by the Share extension (issue #1020). Drained on
    /// every foreground because that is the first moment the app has the keys,
    /// the batch client and the memory budget the extension does not.
    @ObservedObject private var sharedImporter = SharedRecordingImporter.shared
    private let captureHardware = CaptureHardwareProfile.current()
    /// Completion time of the background transcript we last surfaced, so we only
    /// surface a given session once and never clobber the user's in-app edits.
    @State private var lastSurfacedAt: Date?

    public init() {
        let coordinator = TranscriberCoordinator()
        _coordinator = StateObject(wrappedValue: coordinator)
        let handsFree = IOSHandsFreeDictationCoordinator(
            audioSessionManager: coordinator.audioSessionManager,
            startCapture: { preRoll in
                // Earliest app-code observation of this utterance's start.
                let detectedAt = Date()
                let settings = AppSettings.shared
                guard HandsFreeDictationPolicy.supportsCapture(
                    modelID: settings.selectedModel,
                    isStreaming: settings.transcriptionMode == .streaming
                )
                else { return .rejected(.unsupportedConfiguration) }
                do {
                    try await coordinator.start(
                        preRollBuffers: preRoll,
                        analyzerFallbackAllowed: false,
                        entry: StartupEntry(origin: .handsFree, observedAt: detectedAt)
                    )
                    return .started
                } catch {
                    return .rejected(HandsFreeDictationMachine.Failure(error))
                }
            },
            stopCapture: {
                _ = await coordinator.stop(rearmHandsFree: true)
                if case .microphoneChanged? = coordinator.error as? iOSTranscriptionError { return .completed }
                return coordinator.error == nil ? .completed : .failed(.captureFailed)
            },
            cancelCapture: { coordinator.cancel() },
            // iOS has no silence-hold setting, so the shared policy value is
            // the only source. The macOS "silenceDuration" preference lives
            // in the Mac app's own defaults and never reaches this app.
            silenceDuration: { HandsFreeDictationPolicy.defaultSilenceHoldSeconds },
            captureIsSupported: {
                HandsFreeDictationPolicy.supportsCapture(
                    modelID: AppSettings.shared.selectedModel,
                    isStreaming: AppSettings.shared.transcriptionMode == .streaming
                )
            },
            liveActivitiesEnabled: { AppSettings.shared.liveActivitiesEnabled }
        )
        _handsFree = StateObject(wrappedValue: handsFree)
        // A hands-free utterance presents through the coordinator's capture, so
        // it inherits the same proof gate rather than keeping a second one.
        handsFree.captureIsProven = { [weak coordinator] in coordinator?.isPresentingCapture ?? false }
        coordinator.onCapturePresentationChanged = { [weak handsFree] in
            handsFree?.refreshCapturePresentation()
        }
        coordinator.onCaptureDisruption = { [weak coordinator, weak handsFree] in
            if handsFree?.isArmed == true {
                await handsFree?.stopForCaptureDisruption()
            } else {
                _ = await coordinator?.stop()
            }
        }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                // Content layer - transcript display (base plane, no glass)
                VStack {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(
                                alignment: .leading,
                                spacing: density.isCompact ? density.cardContentSpacing : 12
                            ) {
                                if let card = onboarding.offeredCard(hardware: captureHardware) {
                                    CaptureOnboardingCard(
                                        trigger: card,
                                        hasActionButton: captureHardware.hasActionButton
                                    ) {
                                        onboarding.dismissCard(card)
                                    }
                                }
                                if currentText.isEmpty {
                                    Text(backgroundService.isRunning
                                         ? "Recording via Action Button…"
                                         : "Tap the microphone to start transcription")
                                        .font(density.isCompact ? .subheadline : .title3)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.top, density.isCompact ? 24 : 100)
                                } else {
                                    Text(currentText)
                                        .font(density.isCompact ? .body : .title3)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(density.isCompact ? density.pagePadding : 16)
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

                    Spacer(minLength: density.isCompact ? 72 : 120)
                }

                // Controls layer - floating glass controls
                VStack {
                    Spacer()

                    // Floating control cluster with Liquid Glass
                    floatingControls
                        .padding(.horizontal, density.isCompact ? 8 : 20)
                        .padding(.bottom, density.isCompact ? 8 : 30)
                }
            }
            .navigationTitle("Just Speak to It")
            .navigationBarTitleDisplayMode(usesInlineDensityLayout ? .inline : .automatic)
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
                } else if handsFree.isArmed {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.badge.mic")
                                .font(.caption)
                            Text(handsFreeStatusLabel)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Hands-free dictation \(handsFreeStatusLabel.lowercased())")
                        .accessibilityIdentifier("handsFreeArmedIndicator")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: density.isCompact ? 8 : 16) {
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
                        .accessibilityIdentifier("historyNavLink")

                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gear")
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settingsNavLink")
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
            // Audio that survived a crash, offered back once per launch
            // (issue #992). "Not now" keeps the recording exactly where it is;
            // nothing on this path deletes audio.
            .alert("Recording interrupted", isPresented: $showingRecoveryPrompt) {
                Button("Transcribe it") {
                    guard let finding = recovery.recoverable.first else { return }
                    Task { await recovery.recover(finding) }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text(recovery.recoverable.first.map(recovery.promptMessage) ?? "")
            }
            .onChange(of: coordinator.error?.localizedDescription) { _, newError in
                if let error = newError {
                    errorMessage = error
                    showingError = true
                }
            }
            .onChange(of: backgroundService.lastSessionError?.localizedDescription) { _, newError in
                // A background session (Action Button, Home Screen quick
                // action, capture link) failed; surface it instead of silently
                // losing the user's dictation.
                presentSessionError(newError)
            }
            .onChange(of: handsFree.failureMessage) { _, newError in
                if let newError {
                    errorMessage = newError
                    showingError = true
                }
            }
            // A shared recording that could not be transcribed is reported,
            // never swallowed. Successes need no alert: they are in History.
            .onChange(of: sharedImporter.lastOutcome) { _, outcome in
                guard case .failed = outcome, let outcome else { return }
                errorMessage = outcome.message
                showingError = true
                sharedImporter.acknowledgeOutcome()
            }
            .onChange(of: settings.handsFreeDictationEnabled) { _, enabled in
                if !enabled { Task { await handsFree.disarm() } }
            }
            .task {
                // The guided first run owns the microphone until it is done,
                // so never auto-start behind it. Auto-start is reconsidered
                // when onboarding finishes (see the sheet's onDismiss).
                if onboarding.shouldPresentFirstRun {
                    showingFirstRun = true
                } else {
                    await autoStartIfEnabled()
                }
            }
            .onAppear {
                refreshBackgroundState()
                // A Home Screen quick action can cold-launch the app and fail
                // to start before this view — and therefore the observer above
                // — exists, so the failure has to be read as well as watched
                // (issue #944). `presentSessionError` de-duplicates, so the
                // two routes cannot raise two alerts for one failure.
                presentSessionError(backgroundService.lastSessionError?.localizedDescription)
                offerCaptureRecoveryIfNeeded()
                Task { await sharedImporter.drain() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    refreshBackgroundState()
                    Task { await sharedImporter.drain() }
                } else {
                    Task { await handsFree.disarm() }
                }
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
            // Swiping the sheet away counts as finishing it, so first run is
            // offered exactly once and never nags. Auto-start is considered on
            // the way out, so enabling it before onboarding still takes effect
            // on this launch — the onboarding capture has already been stopped
            // by then, and `coordinator.start()` is single-flight regardless.
            .sheet(isPresented: $showingFirstRun, onDismiss: {
                onboarding.completeFirstRun()
                Task { await autoStartIfEnabled() }
            }, content: {
                FirstRunOnboardingView(
                    audioSessionManager: coordinator.audioSessionManager,
                    liveTranscript: coordinator.partialText,
                    startTestDictation: { try await coordinator.start() },
                    stopTestDictation: { await coordinator.stop().text },
                    onFinish: { showingFirstRun = false }
                )
            })
        }
        .environment(\.appVisualDensity, settings.visualDensity)
        .environment(\.defaultMinListRowHeight, settings.visualDensity.minimumListRowHeight)
        .controlSize(density.isCompact ? .small : .regular)
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
        GlassEffectContainer(spacing: density.isCompact ? 8 : 16) {
            HStack(spacing: density.isCompact ? 8 : 16) {
                // Primary action - Start/Stop
                Button {
                    Task {
                        await toggleRecording()
                    }
                } label: {
                    Image(systemName: primaryActionSymbol)
                        .font(.system(size: primarySymbolSize))
                        .frame(width: primaryControlSize, height: primaryControlSize)
                }
                .buttonStyle(.glassProminent)
                .tint(isAnyRecording ? .red : .brandAccent)
                .clipShape(Circle())
                .accessibilityLabel(primaryActionLabel)
                .accessibilityIdentifier("recordToggleButton")

                // Secondary actions (only visible when there's text and not recording)
                if hasTextToShow && !isAnyRecording {
                    // Polish/Post-process button
                    Button {
                        showingPostProcessing = true
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: secondarySymbolSize))
                            .frame(width: secondaryControlSize, height: secondaryControlSize)
                    }
                    .buttonStyle(.glass)
                    .tint(.purple)
                    .clipShape(Circle())
                    .accessibilityLabel("Polish transcript")
                    .accessibilityIdentifier("polishTranscriptButton")
                    .transition(.scale.combined(with: .opacity))

                    // Copy button
                    Button {
                        copyToClipboard()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: secondarySymbolSize))
                            .frame(width: secondaryControlSize, height: secondaryControlSize)
                    }
                    .buttonStyle(.glass)
                    .tint(.brandAccentWarm)
                    .clipShape(Circle())
                    .accessibilityLabel(copied ? "Copied to clipboard" : "Copy transcript")
                    .accessibilityIdentifier("copyTranscriptButton")
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
        HStack(spacing: density.isCompact ? 8 : 16) {
            // Primary action - Start/Stop
            Button {
                Task {
                    await toggleRecording()
                }
            } label: {
                Image(systemName: primaryActionSymbol)
                    .font(.system(size: primarySymbolSize))
                    .frame(width: primaryControlSize, height: primaryControlSize)
            }
            .buttonStyle(.borderedProminent)
            .tint(isAnyRecording ? .red : .accentColor)
            .clipShape(Circle())
            .accessibilityLabel(primaryActionLabel)
            .accessibilityIdentifier("recordToggleButton")

            // Secondary actions (only visible when there's text and not recording)
            if hasTextToShow && !isAnyRecording {
                // Polish/Post-process button
                Button {
                    showingPostProcessing = true
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: secondarySymbolSize))
                        .frame(width: secondaryControlSize, height: secondaryControlSize)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .clipShape(Circle())
                .accessibilityLabel("Polish transcript")
                .accessibilityIdentifier("polishTranscriptButton")
                .transition(.scale.combined(with: .opacity))

                // Copy button
                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: secondarySymbolSize))
                        .frame(width: secondaryControlSize, height: secondaryControlSize)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .accessibilityLabel(copied ? "Copied to clipboard" : "Copy transcript")
                .accessibilityIdentifier("copyTranscriptButton")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasTextToShow)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: coordinator.isRunning)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: backgroundService.isRunning)
    }

    // MARK: - Computed Properties

    private var density: AppVisualDensity {
        settings.visualDensity
    }

    private var usesInlineDensityLayout: Bool {
        density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
    }

    private var primaryControlSize: CGFloat {
        density.isCompact ? 48 : 64
    }

    private var secondaryControlSize: CGFloat {
        density.isCompact ? 44 : 48
    }

    private var primarySymbolSize: CGFloat {
        density.isCompact ? 20 : 28
    }

    private var secondarySymbolSize: CGFloat {
        density.isCompact ? 16 : 20
    }

    private var hasTextToShow: Bool {
        !currentText.isEmpty
    }

    private var isAnyRecording: Bool {
        coordinator.isRunning || backgroundService.isRunning
    }

    private var handsFreeStatusLabel: String {
        switch handsFree.state {
        case .off: return "Off"
        case .arming: return "Arming"
        case .armed: return "Armed"
        case .recording: return "Recording"
        case .finalising: return "Finalising"
        }
    }

    private var primaryActionSymbol: String {
        if isAnyRecording { return "stop.fill" }
        if handsFree.isArmed { return "mic.slash.fill" }
        return "mic.fill"
    }

    private var primaryActionLabel: String {
        if isAnyRecording { return "Stop recording" }
        if handsFree.isArmed { return "Disarm hands-free dictation" }
        if settings.handsFreeDictationActive { return "Arm hands-free dictation" }
        return "Start recording"
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

    /// Starts recording on launch when the user asked for it. Considered once
    /// when onboarding was already complete and once more when the first-run
    /// sheet finishes, so enabling auto-start before onboarding is not silently
    /// dropped for the whole first launch.
    private func autoStartIfEnabled() async {
        guard AppSettings.shared.autoStartRecording else { return }
        guard !coordinator.isRunning, !coordinator.isStartingRecording else { return }
        guard !backgroundService.isRunning else { return }
        do {
            try await coordinator.start()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    /// Presents a background session failure once.
    ///
    /// Called both when the published error changes and when this view
    /// appears — the second is what covers a cold launch, where a quick action
    /// can fail before any observer exists. `CaptureStartFailurePolicy` owns
    /// the "is this new?" rule so both routes agree, and a `nil` (a fresh start
    /// clearing the error) re-arms it, so the *same* failure happening twice is
    /// still shown twice.
    private func presentSessionError(_ description: String?) {
        guard CaptureStartFailurePolicy.shouldPresent(
            description,
            lastPresented: presentedSessionError
        ), let description else {
            if description == nil { presentedSessionError = nil }
            return
        }
        presentedSessionError = description
        errorMessage = description
        showingError = true
    }

    /// Surfaces the most recent background (Action Button / Siri / Shortcuts)
    /// transcript as the current view and updates the History badge. Called on
    /// appear and whenever the app returns to the foreground so a headless
    /// recording is never lost behind a stale in-app transcript.
    /// Offers the oldest interrupted capture back, once per launch, and only
    /// when nothing is recording — a question about yesterday's audio must not
    /// interrupt today's capture.
    private func offerCaptureRecoveryIfNeeded() {
        guard !recovery.hasPromptedThisLaunch, !coordinator.isRunning else { return }
        let plan = recovery.refresh()
        guard !plan.hasLiveCapture, !plan.recoverable.isEmpty else { return }
        recovery.hasPromptedThisLaunch = true
        showingRecoveryPrompt = true
    }

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
        // Earliest app-code observation of this control's press; it survives
        // every await between here and the start path (issue #972).
        let pressedAt = Date()
        if handsFree.state == .recording {
            await handsFree.finishCurrentUtterance()
        } else if handsFree.isArmed {
            await handsFree.disarm()
        } else if backgroundService.isRunning {
            // An in-app stop finishes a headless run where that run asked to
            // finish, not where the global setting points (issue #1013).
            let result = await backgroundService.stopRecording(
                destination: backgroundService.resolvedStopDestination()
            )
            displayText = result.text
        } else if coordinator.isRunning {
            let result = await coordinator.stop()
            logger.info("Final result: \(result.text.count) chars, duration: \(result.duration)s")

            // Auto post-process if enabled
            if settings.autoPostProcess && settings.hasOpenRouterKey && !result.text.isEmpty {
                showingPostProcessing = true
            }
        } else {
            if settings.handsFreeDictationActive {
                await handsFree.toggle()
                return
            }
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
                try await coordinator.start(
                    entry: StartupEntry(origin: .foreground, observedAt: pressedAt)
                )
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
