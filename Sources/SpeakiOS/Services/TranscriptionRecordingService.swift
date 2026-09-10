#if os(iOS)
import Foundation
import UIKit
import SpeakCore

// swiftlint:disable file_length

/// Headless recording coordinator for Action Button / Shortcuts / Siri.
/// Manages the full lifecycle: start recording → live transcription → stop → clipboard → Live Activity.
@MainActor
// swiftlint:disable:next type_body_length
public final class TranscriptionRecordingService: ObservableObject {
    public static let shared = TranscriptionRecordingService()

    /// The service's lifecycle state, mirrored from the run-identity
    /// coordinator after every transition. `isRunning` remains as the
    /// published `recording`-only view for existing observers.
    @Published public private(set) var state: RecordingServiceState = .idle

    /// Whether a stop/toggle has an operation to act on: a live recording or
    /// a startup still in flight (which stop will cancel).
    public var isActive: Bool { lifecycle.isActive }

    @Published public private(set) var isRunning = false
    @Published public private(set) var partialText = ""
    @Published public private(set) var wordCount = 0
    /// Error that ended the most recent session mid-recording. Published so the
    /// app can surface it on next foreground instead of silently losing audio.
    @Published public private(set) var lastSessionError: Error?
    /// Non-nil when the session silently fell back to on-device transcription
    /// because the selected cloud model had no API key available.
    @Published public private(set) var providerFallbackNotice: String?

    private let audioSessionManager = AudioSessionManager()
    private let activityManager = TranscriptionActivityManager.shared
    private let sharedState: SharedTranscriptionState
    private let historyManager: iOSHistoryManager

    private var transcriptionSession: IOSTranscriptionSession?
    private var stoppingSession: IOSTranscriptionSession?
    private var startTime: Date?
    private var currentModel: String = ""
    private var sharesLiveTranscript = true
    private var automaticStopDestination: HardwareTriggerDestination = .clipboard
    private var onCaptureDisruption: (() async -> Void)?
    /// Run-identity state machine for cancellable startup (issue #701); the
    /// pure mechanics live in SpeakCore so they are testable on every
    /// platform. `state` mirrors it for observers.
    private let lifecycle = RecordingLifecycleCoordinator()
    /// Truthful capture presentation (issue #983): startup stays visibly
    /// "preparing" until this run has both started its backend and observed a
    /// buffer from its own live input tap.
    private var presentation = CapturePresentationGate()
    /// Last time the App Group shared state was written for a partial result.
    private var lastSharedStateWriteAt: Date = .distantPast
    private static let sharedStateWriteInterval: TimeInterval = 1.0

    private let polishClipboard: PolishClipboard
    private let hasPolishingKey: @MainActor () -> Bool
    private let polish: @MainActor (String, String, String) async throws -> String
    private var latestCompletionID: UUID?

    private convenience init() {
        self.init(
            sharedState: .shared,
            historyManager: .shared,
            polishClipboard: PolishClipboard(),
            hasPolishingKey: { AppSettings.shared.hasOpenRouterKey },
            polish: { text, model, apiKey in
                try await iOSPostProcessingManager.shared.polish(text: text, model: model, apiKey: apiKey)
            }
        )
    }

    /// Keeps recording lifecycle tests isolated from the real clipboard, History and provider.
    init(
        sharedState: SharedTranscriptionState,
        historyManager: iOSHistoryManager,
        polishClipboard: PolishClipboard,
        hasPolishingKey: @escaping @MainActor () -> Bool,
        polish: @escaping @MainActor (String, String, String) async throws -> String
    ) {
        self.sharedState = sharedState
        self.historyManager = historyManager
        self.polishClipboard = polishClipboard
        self.hasPolishingKey = hasPolishingKey
        self.polish = polish
    }

    /// Picks the first non-blank candidate, else the fallback. Extracted as a
    /// pure function so the stop-time text-selection priority
    /// (result → interim → last-completed) is unit-testable.
    static func bestTranscript(candidates: [String], fallback: String) -> String {
        for candidate in candidates
        where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate
        }
        return fallback
    }

    private var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    private var modelDisplayName: String {
        ModelCatalog.transcriptionDisplayName(
            for: currentModel,
            isBatch: transcriptionSession?.isBatch
                ?? (AppSettings.shared.transcriptionMode == .batch)
        )
    }

    // MARK: - Public API

    /// Starts a headless recording session with Live Activity.
    public func startRecording(
        retainBatchRecording: Bool = true,
        sharesLiveTranscript: Bool = true,
        requiresLiveActivity: Bool = true,
        keyboardProfile: KeyboardDictationProfileOption? = nil
    ) async throws {
        try await startRecording(
            retainBatchRecording: retainBatchRecording,
            sharesLiveTranscript: sharesLiveTranscript,
            requiresLiveActivity: requiresLiveActivity,
            keyboardProfile: keyboardProfile,
            destination: nil
        )
    }

    /// Internal callers can retain their destination and request ownership for an automatic stop.
    func startRecording( // swiftlint:disable:this function_body_length
        retainBatchRecording: Bool = true,
        sharesLiveTranscript: Bool = true,
        requiresLiveActivity: Bool = true,
        keyboardProfile: KeyboardDictationProfileOption? = nil,
        destination: HardwareTriggerDestination?,
        onCaptureDisruption: (() async -> Void)? = nil
    ) async throws {
        guard let runID = lifecycle.beginStart() else { return }
        presentation.begin(run: runID)
        state = lifecycle.state
        defer { state = lifecycle.state }

        let settings = AppSettings.shared
        // AppSettings.init publishes empty API keys and loads the real values
        // from the keychain asynchronously. A cold launch from the Action
        // Button could read those empty keys and silently fall back to Apple
        // Speech, so wait for the initial load before resolving the model.
        await settings.ensureKeysLoaded()
        // A stop/cancel during the suspension above retires the run; nothing
        // has been allocated yet, so unwinding only settles the state machine.
        guard lifecycle.isCurrentStartRun(runID) else {
            unwindCancelledStart()
            throw CancellationError()
        }

        lastSessionError = nil
        providerFallbackNotice = nil
        let usesBatchTranscription = keyboardProfile?.transcriptionMode == .batch
            || (keyboardProfile == nil && settings.transcriptionMode == .batch)
        currentModel = keyboardProfile?.transcriptionModelIdentifier
            ?? (usesBatchTranscription ? settings.batchTranscriptionModel : settings.selectedModel)
        partialText = ""
        wordCount = 0
        lastSharedStateWriteAt = .distantPast
        startTime = Date()
        self.sharesLiveTranscript = sharesLiveTranscript
        self.automaticStopDestination = destination ?? settings.hardwareTriggerDestination
        self.onCaptureDisruption = onCaptureDisruption
        sharedState.clear()
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime

        if !usesBatchTranscription && keyboardProfile == nil {
            resolveLiveModel(settings: settings)
        }

        // A Live Activity is required to record in the *background* via an
        // AudioRecordingIntent — without one the AppIntents system-policy check
        // asserts (EXC_BREAKPOINT). In the foreground a Live Activity is optional,
        // so only enforce this when the app isn't active.
        let appIsActive = UIApplication.shared.applicationState == .active
        let activityProvider = providerFallbackNotice == nil
            ? modelDisplayName
            : "\(modelDisplayName) (no API key)"
        let activityStarted = (requiresLiveActivity || appIsActive)
            ? activityManager.startActivity(provider: activityProvider, initialStatus: .arming)
            : false
        if requiresLiveActivity && !activityStarted && !appIsActive {
            unwindCancelledStart()
            throw iOSTranscriptionError.liveActivityUnavailable
        }

        #if DEBUG && targetEnvironment(simulator)
        if let transcript = sharedState.simulatorValidationTranscript {
            // A synthetic transcript is not observed microphone input, but this
            // DEBUG-only simulator stub has no input tap at all. Resolve the
            // gate explicitly so the harness never sits in preparation.
            presentation.noteBackendStarted(run: runID)
            presentation.noteInputObserved(run: runID)
            handlePartialResult(text: transcript)
            _ = lifecycle.activate(runID)
            state = lifecycle.state
            isRunning = true
            return
        }
        #endif

        var startedSession: IOSTranscriptionSession?
        do {
            let mode: IOSTranscriptionSession.Mode = usesBatchTranscription
                ? .batch(retainRecording: retainBatchRecording)
                : .streaming
            let languageIdentifier = keyboardProfile?.languageIdentifier
                ?? settings.preferredLocaleIdentifier
            let session = try IOSTranscriptionSession(
                modelID: currentModel,
                mode: mode,
                language: TranscriptionLanguageCatalog.providerLanguage(for: languageIdentifier),
                audioSessionManager: audioSessionManager,
                batchAPIKey: settings.batchAPIKey(for: currentModel),
                liveAPIKey: settings.liveAPIKey(for:),
                transcriptionKeywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords)
            )
            session.onPartialResult = { [weak self, weak session] text, _ in
                guard let self, let session,
                      self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session
                        || self.stoppingSession === session else { return }
                self.handlePartialResult(text: text)
            }
            session.onError = { [weak self, weak session] error in
                guard let self, let session,
                      self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session
                        || self.stoppingSession === session else { return }
                self.handleError(error, session: session)
            }
            bindFirstInput(session: session, runID: runID)
            startedSession = session
            guard lifecycle.installStartCancellation(for: runID, cancel: { session.cancel() }) else {
                throw CancellationError()
            }
            try await session.start()
            // The session this run allocated is published only while the run
            // is still current; a stop during start() retires the run, and the
            // cleanup below tears down exactly what this run owns without
            // touching any replacement run's session (issue #701).
            guard lifecycle.activate(runID) else {
                session.cancel()
                unwindCancelledStart()
                throw CancellationError()
            }
            transcriptionSession = session
            isRunning = true
            // The tap can deliver before `start()` returns, so this may be the
            // second half of the pair rather than the first.
            notePresentation(presentation.noteBackendStarted(run: runID))
        } catch {
            // Unwind runs for the retired case too: a stop that cancelled this
            // startup is awaiting settlement, and this run still owns whatever
            // it allocated. `transcriptionSession` is untouched — it is only
            // ever assigned after successful activation.
            startedSession?.cancel()
            unwindCancelledStart()
            throw error
        }
    }

    private func resolveLiveModel(settings: AppSettings) {
        let requestedModel = currentModel
        let route = LiveTranscriptionRouting.route(for: currentModel)
        currentModel = LiveTranscriptionRouting.resolvedModelID(
            for: currentModel,
            apiKey: route.map { settings.liveAPIKey(for: $0) }
        )
        if currentModel != requestedModel {
            // Make the silent on-device fallback visible: publish it for
            // the UI and log it so a "worse than usual" session is
            // diagnosable.
            providerFallbackNotice = "Using \(modelDisplayName) (no API key)"
            SpeakLogger.transcription.warning(
                """
                No API key for \(requestedModel, privacy: .public); \
                falling back to \(self.currentModel, privacy: .public)
                """
            )
        }
    }

    /// Reverts everything a cancelled startup run had published: timing,
    /// shared App Group recording state and the Live Activity. The run calls
    /// this itself so ownership never crosses runs.
    private func unwindCancelledStart() {
        startTime = nil
        sharesLiveTranscript = true
        partialText = ""
        wordCount = 0
        sharedState.clearRecordingState()
        presentation.finish()
        activityManager.endActivity()
        lifecycle.finishStartUnwind()
        state = lifecycle.state
    }

    /// Stops recording, applies the requested result destination, and returns the result.
    ///
    /// - Parameter destination: Where the transcript should go. When `nil`, defaults
    ///   to `.clipboardAndPostProcess` if the user has post-processing turned on,
    ///   else `.clipboard` — i.e., the original behaviour before destinations
    ///   were configurable. Hardware-trigger callers (Action Button, Siri,
    ///   Shortcuts) pass `AppSettings.shared.hardwareTriggerDestination`.
    @discardableResult
    // swiftlint:disable:next function_body_length
    public func stopRecording(
        destination: HardwareTriggerDestination? = nil,
        saveToHistory: Bool = true,
        primedActivityMessage: String = "Ready for the Action Button"
    ) async -> TranscriptionResult {
        // A stop during startup cancels the pending run and waits for it to
        // unwind (issue #701): retiring `activeStartRunID` makes the suspended
        // start release everything it allocated instead of activating the
        // microphone after the user asked to stop.
        if lifecycle.state == .starting {
            lifecycle.retireStartRun()
            await lifecycle.awaitStartSettled()
            state = lifecycle.state
            return TranscriptionResult(
                text: "",
                segments: [],
                confidence: nil,
                duration: 0,
                modelIdentifier: currentModel,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }

        // Reentrancy guard: a rapid double-stop (e.g. double Action Button
        // press) must not produce a second history entry or clobber the
        // clipboard with stale text. Return an empty no-op result instead.
        guard lifecycle.beginStopping() else {
            return TranscriptionResult(
                text: "",
                segments: [],
                confidence: nil,
                duration: 0,
                modelIdentifier: currentModel,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }
        state = lifecycle.state
        isRunning = false
        presentation.finish()
        let duration = elapsedSeconds
        let completionID = UUID()
        latestCompletionID = completionID

        // Keep the (often headless / backgrounded) process alive long enough for
        // the clipboard write — and any post-processing — to actually commit.
        // Short recordings were being suspended before the pasteboard flush
        // landed, so "Copied N words" was reported but nothing arrived.
        let assertion = beginBackgroundAssertion("Finalise transcription")

        if transcriptionSession?.isBatch == true {
            activityManager.updateActivity(
                status: .processing,
                lastSnippet: "Transcribing recording…",
                wordCount: 0,
                duration: duration
            )
        }

        let drained = await drainActiveTranscriber(duration: duration)
        startTime = nil

        // Use the best available text and make the returned result, the history
        // entry, the clipboard, and the spoken dialog all agree on it.
        let text = bestAvailableText(from: drained)
        let result = drained.replacingText(text)
        partialText = text
        wordCount = text.split(whereSeparator: \.isWhitespace).count

        // Specialized callers may opt out when their result is intentionally transient.
        let historyItem = saveToHistory
            ? historyManager.recordTranscription(
                text: text,
                model: currentModel,
                duration: result.duration
            )
            : nil

        // Resolve the destination. When nil (legacy callers), preserve the
        // pre-destination behaviour: clipboard + post-process if user opted in.
        let resolvedDestination: HardwareTriggerDestination = destination ?? .clipboard
        let receipt = applyDestinationSideEffects(text: text, destination: resolvedDestination)

        // Update shared state. Live writes are throttled, so commit the
        // complete transcript exactly once at stop.
        if sharesLiveTranscript {
            sharedState.updateTranscript(text)
        }
        sharedState.clearRecordingState()
        sharesLiveTranscript = true

        // Complete Live Activity with clipboard confirmation
        completeRecordingActivity(
            duration: duration,
            primedMessage: lastSessionError?.localizedDescription ?? primedActivityMessage
        )

        // Kick off background post-processing if the chosen destination + user
        // settings call for it. The polished clipboard write must also survive
        // process suspension, so the background assertion is released only once
        // post-processing has finished.
        if shouldPostProcess(destination: resolvedDestination, isLegacyCaller: destination == nil)
            && !text.isEmpty {
            if let historyItem {
                historyManager.beginPostProcessing(for: historyItem.id)
            }
            startPostProcessing(
                text: text,
                historyItemID: historyItem?.id,
                completionID: completionID,
                receipt: receipt,
                assertion: assertion
            )
        } else {
            assertion.end()
        }

        // Clear per-session live state so a duplicate stop or a later fallback
        // path can never resurface this session's text.
        partialText = ""
        wordCount = 0

        lifecycle.finishStopping()
        state = lifecycle.state
        return result
    }

    private func completeRecordingActivity(duration: Int, primedMessage: String) {
        activityManager.completeActivity(
            finalWordCount: wordCount,
            duration: duration,
            keepPrimed: true,
            primedMessage: primedMessage
        )
    }

    /// Cancels recording without saving. During startup this retires the
    /// pending run and cancels its allocated provider immediately. The owned
    /// startup task unwinds before another run can begin (issues #701, #786).
    public func cancelRecording() {
        // A completed recording's polish has its own lifetime. Cancelling a
        // subsequent capture must not cancel that work or invalidate its result.
        if lifecycle.state == .stopping {
            latestCompletionID = nil
            // The current finalisation keeps ownership until its drain ends.
            // A replacement must not start while it can still publish output.
            return
        }
        if lifecycle.state == .starting {
            lifecycle.retireStartRun()
            return
        }
        transcriptionSession?.cancel()
        transcriptionSession = nil
        sharesLiveTranscript = true
        isRunning = false
        presentation.finish()
        startTime = nil
        partialText = ""
        wordCount = 0
        sharedState.clearRecordingState()
        activityManager.endActivity()
        lifecycle.finishStopping()
        state = lifecycle.state
    }

    // MARK: - Private

    private func handlePartialResult(text: String) {
        partialText = text

        // App Group writes (plist + cfprefsd IPC) and word counting are O(n)
        // per partial; throttle them to ~1/s, mirroring the Live Activity
        // manager's own update throttle. The full transcript is committed
        // once more at stop.
        let now = Date()
        if now.timeIntervalSince(lastSharedStateWriteAt) >= Self.sharedStateWriteInterval {
            lastSharedStateWriteAt = now
            wordCount = text.split(separator: " ").count
            if sharesLiveTranscript {
                sharedState.updateTranscript(text)
            }
        }

        // Presentation only: the transcript above is delivered either way. A
        // partial can arrive from pre-roll before this run has seen its own
        // input, and it must not announce active capture (issue #983).
        guard presentation.isPresentingCapture else {
            publishPreparingActivity()
            return
        }
        activityManager.updateActivity(
            status: .listening,
            lastSnippet: text,
            wordCount: wordCount,
            duration: elapsedSeconds
        )
    }

    /// Routes this run's own first live buffer into the presentation gate.
    private func bindFirstInput(session: IOSTranscriptionSession, runID: UUID) {
        session.onFirstInputBuffer = { [weak self, weak session] in
            guard let self, let session,
                  self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session
            else { return }
            self.notePresentation(self.presentation.noteInputObserved(run: runID))
        }
    }

    /// Publishes the one arming → recording transition, and only that one.
    private func notePresentation(_ promoted: Bool) {
        guard promoted else { return }
        activityManager.updateActivity(
            status: .recording,
            lastSnippet: partialText,
            wordCount: wordCount,
            duration: elapsedSeconds
        )
    }

    /// Keeps preparation truthful: no snippet, no elapsed time, no recording
    /// indicator until this run's own tap has delivered.
    private func publishPreparingActivity() {
        activityManager.updateActivity(
            status: .arming,
            lastSnippet: CapturePresentationGate.preparingMessage,
            wordCount: 0,
            duration: 0
        )
    }

    private func handleError(_ error: Error, session: IOSTranscriptionSession) {
        activityManager.reportError(error.localizedDescription)

        // A mid-session failure previously only updated the Live Activity —
        // the mic stayed hot while the user dictated into a dead session.
        // Tear the session down, preserving the accumulated transcript, and
        // publish the error so the app can surface it on next foreground.
        guard lifecycle.state == .recording || stoppingSession === session else { return }
        lastSessionError = error
        guard lifecycle.state == .recording else { return }
        Task { [weak self] in
            guard let self, self.isRunning, self.transcriptionSession === session else { return }
            await self.finishCaptureAfterDisruption()
        }
    }

    /// Finishes through the originating owner, which may own a keyboard nonce
    /// rather than a clipboard destination. Stop's lifecycle guard claims once.
    func finishCaptureAfterDisruption() async {
        guard lifecycle.state == .recording else { return }
        if let finishOwnedCapture = onCaptureDisruption {
            await finishOwnedCapture()
            return
        }
        await stopRecording(
            destination: automaticStopDestination,
            primedActivityMessage: lastSessionError?.localizedDescription ?? "Recording stopped"
        )
    }

    private func startPostProcessing(
        text: String,
        historyItemID: UUID?,
        completionID: UUID,
        receipt: PolishClipboard.Receipt?,
        assertion: BackgroundTaskAssertion
    ) {
        let settings = AppSettings.shared
        let model = settings.postProcessingModel
        let apiKey = settings.openRouterAPIKey
        let historyManager = self.historyManager
        let polish = self.polish
        let operation = AutomaticPolishOperation(
            clipboard: polishClipboard,
            receipt: receipt,
            isCurrent: { [weak self] in self?.latestCompletionID == completionID },
            success: { [weak self] polished, current in
                if current {
                    self?.sharedState.lastCompletedTranscript = polished
                }
                if let historyItemID {
                    historyManager.setPostProcessed(polished, for: historyItemID)
                }
            },
            failure: { error in
                if let historyItemID {
                    historyManager.setError(error.localizedDescription, for: historyItemID)
                }
            },
            completion: {
                if let historyItemID {
                    historyManager.endPostProcessing(for: historyItemID)
                }
                assertion.end()
            }
        )
        operation.start(under: assertion, isActive: UIApplication.shared.applicationState == .active) {
            try await polish(text, model, apiKey)
        }
    }
}

// MARK: - Stop helpers

@MainActor
extension TranscriptionRecordingService {
    /// Raw text is usable immediately, including while polishing or without a key.
    static func clipboardTextAtStop(
        transcript: String,
        destination: HardwareTriggerDestination
    ) -> String? {
        guard !transcript.isEmpty else { return nil }
        switch destination {
        case .clipboard, .clipboardAndPostProcess:
            return transcript
        case .historyOnly:
            return nil
        }
    }

    static func legacySharedTranscript(_ transcript: String, sharesCompletedTranscript: Bool) -> String? {
        sharesCompletedTranscript ? transcript : nil
    }
}

private extension TranscriptionRecordingService {
    /// Stops whichever transcriber is currently active and returns its result.
    /// Falls back to a synthetic `TranscriptionResult` built from `partialText`
    /// if no transcriber is wired up (defensive — shouldn't happen in practice).
    ///
    /// We null out the transcriber property **before** awaiting `stop()` to be
    /// safe under `@MainActor` reentrancy: a rapid double-press of the Action
    /// Button can re-enter `stopRecording` while the first stop is suspended,
    /// and otherwise both calls would see the same non-nil transcriber and try
    /// to stop it twice.
    func drainActiveTranscriber(duration: Int) async -> TranscriptionResult {
        if let session = transcriptionSession {
            transcriptionSession = nil
            stoppingSession = session
            defer { stoppingSession = nil }
            do {
                return try await session.stop()
            } catch {
                handleError(error, session: session)
                return TranscriptionResult(
                    text: "",
                    segments: [],
                    confidence: nil,
                    duration: TimeInterval(duration),
                    modelIdentifier: currentModel,
                    cost: nil,
                    rawPayload: nil,
                    debugInfo: nil
                )
            }
        }
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

    /// Applies the destination's side-effects (clipboard write, shared state
    /// update). History recording is handled by the caller because it always
    /// happens regardless of destination.
    func applyDestinationSideEffects(
        text: String,
        destination: HardwareTriggerDestination,
        sharesCompletedTranscript: Bool? = nil
    ) -> PolishClipboard.Receipt? {
        guard !text.isEmpty else { return nil }
        var receipt: PolishClipboard.Receipt?
        if let clipboardText = Self.clipboardTextAtStop(
            transcript: text,
            destination: destination
        ) {
            receipt = polishClipboard.copyRaw(clipboardText)
        }

        // Keyboard handoffs keep their result solely in the nonce-scoped store.
        // Other destinations publish the completed transcript so the Live
        // Activity and foreground handoff can surface it.
        if let sharedTranscript = Self.legacySharedTranscript(
            text,
            sharesCompletedTranscript: sharesCompletedTranscript ?? sharesLiveTranscript
        ) {
            sharedState.lastCompletedTranscript = sharedTranscript
        }
        return receipt
    }

    /// The most complete transcript we can produce at stop time. The transcriber
    /// result is preferred, but for very short recordings the provider may return
    /// empty while interim text is still held in `partialText` — falling back
    /// there keeps the clipboard and dialog honest. We deliberately do NOT fall
    /// back to the last completed transcript: a silent new session must stay
    /// empty rather than re-emitting the previous recording's text.
    func bestAvailableText(from result: TranscriptionResult) -> String {
        TranscriptionRecordingService.bestTranscript(
            candidates: [result.text, partialText],
            fallback: result.text
        )
    }

    /// Begins a finite-length background assertion so a headless / backgrounded
    /// process isn't suspended before the clipboard (and any post-processing)
    /// write commits. The returned object ends the task exactly once.
    func beginBackgroundAssertion(_ name: String) -> BackgroundTaskAssertion {
        BackgroundTaskAssertion(name: name)
    }

    /// Decides whether to run the background post-processor.
    ///
    /// Two paths trigger it:
    /// 1. Legacy callers (no explicit destination) honour the global
    ///    `autoPostProcess` toggle for backwards compatibility.
    /// 2. Hardware-trigger callers explicitly choose `.clipboardAndPostProcess`.
    func shouldPostProcess(
        destination: HardwareTriggerDestination,
        isLegacyCaller: Bool
    ) -> Bool {
        let settings = AppSettings.shared
        switch destination {
        case .clipboardAndPostProcess:
            return hasPolishingKey()
        case .clipboard:
            return isLegacyCaller && settings.autoPostProcess && hasPolishingKey()
        case .historyOnly:
            return false
        }
    }
}

extension TranscriptionResult {
    /// Returns a copy with `text` replaced, preserving all other metadata. Used
    /// so the returned result, history entry, clipboard, and spoken dialog all
    /// agree on the same best-available transcript.
    func replacingText(_ newText: String) -> TranscriptionResult {
        TranscriptionResult(
            text: newText,
            segments: segments,
            confidence: confidence,
            duration: duration,
            modelIdentifier: modelIdentifier,
            cost: cost,
            rawPayload: rawPayload,
            debugInfo: debugInfo
        )
    }
}

/// Reference-type wrapper around a UIKit background-task assertion that
/// guarantees `endBackgroundTask` is called exactly once — whether via the
/// normal completion path or the system expiration handler — avoiding the
/// double-end API violation.
@MainActor
final class BackgroundTaskAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false
    private var expired = false
    private let endTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
    var isValid: Bool { !ended && identifier != .invalid }
    var onExpiration: (() -> Void)? {
        didSet {
            if expired { onExpiration?() }
        }
    }

    init(
        name: String,
        begin: @MainActor (String, @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: $0, expirationHandler: $1)
        },
        end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    ) {
        endTask = end
        let allocated = begin(name) { [weak self] in
            guard let self else { return }
            self.expired = true
            self.onExpiration?()
            self.end()
        }
        // Expiration can arrive before begin returns its identifier.
        if ended {
            if allocated != .invalid { endTask(allocated) }
        } else {
            identifier = allocated
        }
    }

    func end() {
        guard !ended else { return }
        ended = true
        onExpiration = nil
        if identifier != .invalid { endTask(identifier) }
        identifier = .invalid
    }
}
#endif
