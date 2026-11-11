#if os(iOS)
import AVFoundation
import Combine
import SpeakCore
import UIKit

// swiftlint:disable file_length
/// Foreground recording coordinator backed by the shared iOS transcription factory.
/// Integrates with Live Activity for lock screen presence.
@MainActor
// swiftlint:disable:next type_body_length
final class TranscriberCoordinator: ObservableObject {
    private enum LifecycleError: LocalizedError {
        case sessionBusy

        var errorDescription: String? {
            "A transcription is already starting, recording or finalising."
        }
    }

    /// The foreground lifecycle, mirrored from the run-identity coordinator
    /// after every transition (#943). `isRunning` keeps its recording-only
    /// meaning for existing observers; `starting` and `stopping` are visible
    /// here so the button and the auto-start can stay on one action.
    @Published private(set) var state: RecordingServiceState = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var partialText = ""
    @Published private(set) var error: Error? {
        didSet { if error == nil { issueFailureSnapshot = IOSIssueReporter.failedRequest() } }
    }
    private(set) var issueFailureSnapshot = IOSIssueReporter.failedRequest()
    private var requestDiagnostics = IOSRequestDiagnosticState()

    func issueSnapshot(failedStart run: UUID?) -> IOSIssueReportSnapshot {
        requestDiagnostics.failedStartSnapshot(for: run)
    }
    @Published private(set) var recordingWarning: String?
    @Published private(set) var currentModel: String = AppleLocalModels.preferredSpeechModelID
    @Published private(set) var confidence: Double?
    @Published private(set) var wordCount: Int = 0

    let audioSessionManager: AudioSessionManager
    private let activityManager = TranscriptionActivityManager.shared
    private let sharedState: SharedTranscriptionState
    private let historyManager: iOSHistoryManager
    private let sessionFactory: (() throws -> IOSTranscriptionSession)?
    /// Process-local ownership the Control and intent start guards consume
    /// (#943). Claimed before the first suspension in `start` and released only
    /// once startup unwind, cancellation cleanup or the owned stop has settled,
    /// so a persisted display flag is never what decides whether a headless
    /// session may open the microphone.
    private let ownership: ForegroundRecordingOwnership
    /// The same run-identity state machine the headless service uses (issue
    /// #701): one run owns the microphone from `beginStart` to settlement, a
    /// retired run cannot activate, and a stop that cancels a pending start
    /// can wait for it to unwind.
    private let lifecycle = RecordingLifecycleCoordinator()
    /// Exclusive ownership of provider startup, so a second call while the
    /// first is still awaiting `session.start` cannot create a second session
    /// and leave the earlier one capturing (#943). This is the same guard the
    /// transcribers use; the coordinator does not invent its own.
    private let startup = RecordingStartupOperation()
    private var ownedRunID: UUID?
    private var startupFailure: Error?
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startingSession: (any IOSRecordingSession)?
    private let ensureKeysLoaded: @MainActor () async -> Void
    private let liveActivitiesEnabled: @MainActor () -> Bool
    private let headlessState: @MainActor () -> RecordingServiceState
    private let networkSnapshot: CaptureNetworkPathMonitor.SnapshotProvider
    private let localRecognitionCapability: @MainActor (String) -> AppleLocalRecognitionCapability

    private var transcriptionSession: (any IOSRecordingSession)?
    private var stoppingSession: (any IOSRecordingSession)?
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
    /// Why the capture in flight is being finished by its owner: a controlled
    /// audio interruption when one has been noticed, else the engine changed.
    var captureDisruptionReason: iOSTranscriptionError {
        captureStopNotice == nil ? .microphoneChanged : .interrupted
    }
    var makeSession: (() throws -> any IOSRecordingSession)?
    /// Queues an offline on-device capture for a cloud upgrade (issue #999).
    var tagOfflineCapture: (iOSHistoryItem, UUID, String) -> Void = {
        OfflineTranscriptUpgrader.shared.tag(item: $0, recordingID: $1, intendedModelID: $2)
    }
    /// The cloud model this run would have used had the network been up.
    private var offlineIntendedModel: String?
    @Published private(set) var captureStopNotice: String?
    private var startTime: Date?
    /// Last time the App Group shared state was written for a partial result.
    private var lastSharedStateWriteAt: Date = .distantPast
    private static let sharedStateWriteInterval: TimeInterval = 1.0

    init(
        sharedState: SharedTranscriptionState = .shared,
        historyManager: iOSHistoryManager = .shared,
        sessionFactory: (() throws -> IOSTranscriptionSession)? = nil,
        ownership: ForegroundRecordingOwnership? = nil,
        ensureKeysLoaded: @escaping @MainActor () async -> Void = { await AppSettings.shared.ensureKeysLoaded() },
        liveActivitiesEnabled: @escaping @MainActor () -> Bool = { AppSettings.shared.liveActivitiesEnabled },
        headlessState: @escaping @MainActor () -> RecordingServiceState = {
            TranscriptionRecordingService.shared.state
        },
        networkSnapshot: @escaping CaptureNetworkPathMonitor.SnapshotProvider = { .unknown },
        localRecognitionCapability: @escaping @MainActor (String) -> AppleLocalRecognitionCapability =
            { _ in .available }
    ) {
        self.audioSessionManager = AudioSessionManager()
        self.sharedState = sharedState
        self.historyManager = historyManager
        self.sessionFactory = sessionFactory
        self.ownership = ownership ?? .shared
        self.ensureKeysLoaded = ensureKeysLoaded
        self.liveActivitiesEnabled = liveActivitiesEnabled
        self.headlessState = headlessState
        self.networkSnapshot = networkSnapshot
        self.localRecognitionCapability = localRecognitionCapability
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

    /// True while a start is in flight — from the claim before the first
    /// suspension until that run has activated or unwound. UI that toggles
    /// recording uses this to stay on one action until startup settles.
    var isStartingRecording: Bool { lifecycle.state == .starting }

    /// Starts an owned foreground run.
    ///
    /// Ownership is claimed synchronously, before the credentials wait or any
    /// other suspension, and is what the Control and intent start guards read.
    /// A duplicate start — a second tap, an auto-start overlapping a tap, or a
    /// hands-free utterance while the app is already capturing — throws rather
    /// than allocating a second session or reporting a start it did not make.
    /// A cancelled start throws `CancellationError` and never activates.
    ///
    /// - Parameter entry: the earliest app-code entry the caller observed.
    ///   Callers with no earlier observation pass `nil` and the coordinator
    ///   times its own entry (issue #972).
    /// - Parameter handle: binds a hands-free owner's later stop/cancel to the
    ///   run this call acquired, so a rejected start cannot act on somebody
    ///   else's recording.
    func start(
        preRollBuffers: [AVAudioPCMBuffer] = [],
        analyzerFallbackAllowed: Bool = true,
        entry: StartupEntry? = nil,
        handle: ForegroundCaptureHandle? = nil
    ) async throws {
        try Task.checkCancellation()
        guard headlessState() == .idle, !ownership.isOwned,
              let runID = lifecycle.beginStart() else { throw LifecycleError.sessionBusy }
        // No suspension between checking the headless service and claiming the foreground.
        _ = ownership.claim(runID)
        ownedRunID = runID
        handle?.runID = runID
        state = .starting
        error = nil
        startupFailure = nil
        beginRun(runID, entry: entry)
        do {
            try await startup.run { [self] in
                try await startOwnedRun(runID, preRollBuffers: preRollBuffers,
                                        analyzerFallbackAllowed: analyzerFallbackAllowed)
            }
            try checkStart(runID)
            if let startupFailure { throw startupFailure }
            guard lifecycle.activate(runID) else { throw CancellationError() }
            startingSession = nil
            markRecordingStarted()
            if transcriptionSession != nil {
                // The tap can deliver before `start()` returns, so this may be
                // the second half of the pair rather than the first. The
                // simulator stub resolved both halves itself.
                notePresentation(presentation.noteBackendStarted(run: runID))
                diagnostics.finish(.started, run: runID)
            }
        } catch {
            var cancelled = !lifecycle.isCurrentStartRun(runID) || error is CancellationError || Task.isCancelled
            // Retiring the run fires the cancellation installed for exactly the
            // session this run allocated; ownership is held until that
            // provider's own cleanup has settled, so a replacement can never
            // overlap it.
            lifecycle.retireStartRun()
            await startingSession?.awaitCancellationSettled()
            cancelled = cancelled || state == .stopping || Task.isCancelled
            startingSession = nil
            startupFailure = nil
            transcriptionSession = nil
            startTime = nil
            partialText = ""
            wordCount = 0
            confidence = nil
            finishStartupDiagnostics(runID: runID, error: cancelled ? CancellationError() : error)
            finishPresentation()
            sharedState.clear()
            sharedState.clearRecordingState()
            if liveActivitiesEnabled() { activityManager.endActivity() }
            lifecycle.finishStartUnwind()
            releaseOwnership()
            state = lifecycle.state
            if cancelled {
                // Intentional cancellation is the user getting what they asked
                // for: no provider error, no result, no History entry.
                self.error = nil
                throw CancellationError()
            }
            throw error
        }
    }

    /// Binds this run's provider callbacks. Ownership of a callback is the
    /// run-and-session identity `acceptsCallback` decides, so a retired
    /// startup or a replaced session can publish nothing (#943).
    private func bindCallbacks(to session: any IOSRecordingSession, runID: UUID) {
        session.onPartialResult = { [weak self, weak session] text, isFinal in
            guard let self, let session, self.acceptsCallback(runID, session: session) else { return }
            self.noteFirstLivePartial(text: text, isFinal: isFinal, runID: runID)
            self.handlePartialResult(text: text, isFinal: isFinal)
            self.confidence = session.confidence
        }
        session.onRecordingWarning = { [weak self, weak session] message in
            guard let self, let session, self.acceptsCallback(runID, session: session) else { return }
            self.handleRecordingWarning(message)
        }
        session.onError = { [weak self, weak session] error in
            guard let self, let session, self.acceptsCallback(runID, session: session),
                  !(error is CancellationError) else { return }
            if self.lifecycle.state == .starting {
                // Startup reports its failure only after cancellation has been ruled out.
                self.startupFailure = error
                return
            }
            self.handleError(error)
            guard Self.requiresControlledStop(error) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.transcriptionSession === session, self.isRunning else { return }
                if let onCaptureDisruption = self.onCaptureDisruption {
                    await onCaptureDisruption()
                } else {
                    _ = await self.stop()
                }
            }
        }
    }

    private func checkStart(_ runID: UUID) throws {
        try Task.checkCancellation()
        guard lifecycle.isCurrentStartRun(runID) else { throw CancellationError() }
    }

    /// Whether a provider callback belongs to the run and session that are
    /// current *now*. A retired startup, a replaced session or a cancelled
    /// stop cannot publish text, errors, flags or Live Activity changes; the
    /// stop in progress still receives its own final partials.
    private func acceptsCallback(_ runID: UUID, session: any IOSRecordingSession) -> Bool {
        guard ownedRunID == runID else { return false }
        switch lifecycle.state {
        case .starting: return lifecycle.isCurrentStartRun(runID) && startingSession === session
        case .recording: return transcriptionSession === session
        case .stopping: return !stopWasCancelled && stoppingSession === session
        case .idle: return false
        }
    }

    private func releaseOwnership() {
        if let ownedRunID {
            requestDiagnostics.retire(ownedRunID)
            ownership.release(ownedRunID)
        }
        ownedRunID = nil
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func markRecordingStarted() {
        state = lifecycle.state
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

        if lifecycle.state == .stopping {
            // A final partial delivered by the drain describes finalisation,
            // never active capture.
            guard liveActivitiesEnabled() else { return }
            activityManager.updateActivity(
                status: .finalising,
                lastSnippet: text,
                wordCount: wordCount,
                duration: elapsedSeconds
            )
            return
        }
        publishTranscriptActivity(text: text)
    }

    /// Hands-free stop, bound to the run its start acquired: a stale handle
    /// returns an empty result and leaves the current recording alone.
    ///
    /// `rearmHandsFree` keeps main's contract: a non-nil closure marks the
    /// hands-free lane and its result decides whether the Live Activity rearms
    /// (#942/#1040), so the ownership binding adds identity without changing
    /// that policy.
    func stop(
        handle: ForegroundCaptureHandle,
        rearmHandsFree: @escaping @MainActor () -> Bool
    ) async -> TranscriptionResult {
        guard let runID = handle.runID, ownedRunID == runID else { return emptyResult() }
        return await stop(rearmHandsFree: rearmHandsFree)
    }

    func cancel(handle: ForegroundCaptureHandle) {
        guard let runID = handle.runID, ownedRunID == runID else { return }
        cancel()
    }

    /// Cancels a pending startup and waits for it to unwind. Retire before
    /// suspending, so nothing that runs while this waits can be mistaken for
    /// a replacement start.
    func cancelStartup() async {
        guard lifecycle.state == .starting else { return }
        cancel()
        await lifecycle.awaitStartSettled()
    }

    func stop(rearmHandsFree: (@MainActor () -> Bool)? = nil) async -> TranscriptionResult {
        if lifecycle.state == .starting {
            await cancelStartup()
            return emptyResult()
        }
        // Reentrancy guard: a second stop while this one drains has nothing
        // left to act on, and must not produce a second result or History entry.
        guard lifecycle.beginStopping() else { return emptyResult() }
        state = lifecycle.state
        defer {
            lifecycle.finishStopping()
            releaseOwnership()
            state = lifecycle.state
        }
        isRunning = false
        finishPresentation()
        sharedState.clearRecordingState()
        let duration = elapsedSeconds

        if liveActivitiesEnabled() {
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
        session: any IOSRecordingSession,
        duration: Int,
        rearmHandsFree: (@MainActor () -> Bool)?
    ) async -> TranscriptionResult? {
        transcriptionSession = nil
        stoppingSession = session
        stopWasCancelled = false
        defer {
            if stoppingSession === session {
                recordingWarning = session.recordingLossSummary
                stoppingSession = nil
            }
        }
        let drained: TranscriptionResult
        do {
            if rearmHandsFree != nil {
                drained = try await HandsFreeCaptureFinalisation(timeout: .seconds(session.stopCompletionTimeout)).run {
                    try await session.stop()
                } cancelCapture: {
                    session.onPartialResult = nil
                    session.onError = nil
                    session.cancel()
                }
            } else {
                drained = try await session.stop()
            }
        } catch {
            // A drain that failed leaves capture to unwind; ownership is held
            // until the provider's own cleanup has settled, so no replacement
            // can overlap this one (#943).
            session.cancel()
            await session.awaitCancellationSettled()
            guard !Task.isCancelled, !stopWasCancelled, stoppingSession === session else { return nil }
            if !(error is CancellationError) { handleError(error) }
            // A hands-free drain failure must retain the same shared/History
            // outcome as Stop (#942), and so must a capture the user did not
            // end -- an interruption finalises through this owner and keeps its
            // partial (#936). Explicit Cancel still clears content above.
            guard rearmHandsFree != nil || captureStopNotice != nil else { return nil }
            drained = TranscriptionResult(
                text: partialText, segments: [], confidence: confidence, duration: TimeInterval(duration),
                modelIdentifier: currentModel, cost: nil, rawPayload: nil, debugInfo: nil
            )
        }
        let result = drained.replacingText(TranscriptionRecordingService.bestTranscript(
            candidates: [drained.text, partialText], fallback: ""
        ))
        guard !Task.isCancelled, !stopWasCancelled, stoppingSession === session else {
            // An explicit Cancel during the drain discards the utterance; the
            // claim is held until the provider has finished cleaning up (#943).
            await session.awaitCancellationSettled()
            startTime = nil
            return result
        }
        partialText = result.text
        wordCount = result.text.split(whereSeparator: \.isWhitespace).count
        updateActivityAfterStop(duration: duration, result: result, rearmHandsFree: rearmHandsFree)
        return await finishStop(
            with: result, recordingWarning: session.recordingLossSummary, recordingID: session.safetyRecordingID
        )
    }

    private func updateActivityAfterStop(
        duration: Int,
        result: TranscriptionResult,
        rearmHandsFree: (@MainActor () -> Bool)?
    ) {
        guard liveActivitiesEnabled() else { return }
        let shouldRearm = rearmHandsFree?() == true
        if rearmHandsFree != nil, !shouldRearm {
            // End synchronously so an old completion cannot clear a later arm's activity.
            activityManager.endActivity()
        } else {
            activityManager.completeActivity(
                finalWordCount: wordCount,
                duration: duration,
                keepPrimed: shouldRearm && captureStopNotice == nil,
                primedMessage: captureStopNotice ?? "Hands-free armed",
                primedStatus: shouldRearm ? .armed : .idle,
                completionOutcome: .unconfirmed(transcript: result.text),
                resultPreview: TranscriptionResultRow.preview(for: result.text)
            )
        }
    }

    private func finishStop(
        with result: TranscriptionResult, recordingWarning: String?, recordingID: UUID?
    ) async -> TranscriptionResult {
        // Live shared-state writes are throttled; commit the final transcript
        // once so the copy intents always see the complete text.
        sharedState.updateTranscript(result.text)
        // Onboarding progress is only ever earned by a transcript that really
        // arrived; a blank one is ignored by the policy.
        CaptureOnboardingStore.shared.recordDictation(trigger: .inApp, transcript: result.text)
        let item = await historyManager.recordTranscriptionAndWait(
            text: result.text,
            model: currentModel,
            duration: result.duration,
            errorMessage: recordingWarning.map { warning in
                [warning, error?.localizedDescription].compactMap { $0 }.joined(separator: " ")
            }
        )
        if let item, let intended = offlineIntendedModel, let recordingID {
            tagOfflineCapture(item, recordingID, intended)
        }
        startTime = nil
        return result
    }

    private func emptyResult() -> TranscriptionResult {
        TranscriptionResult(text: "", segments: [], confidence: nil, duration: 0,
                            modelIdentifier: currentModel, cost: nil, rawPayload: nil, debugInfo: nil)
    }

    /// Cancels and waits until this owner has released — startup unwound, or
    /// the cancelled provider's cleanup settled.
    func cancelAndWait() async {
        guard let runID = ownedRunID else { return }
        cancel()
        guard ownedRunID == runID else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func cancel() {
        // A retired run's loss notice goes with it, whatever state it is in —
        // including an idle coordinator still showing the previous run's (#950).
        recordingWarning = nil
        if lifecycle.state == .starting {
            // Retire first: the suspended start unwinds what it allocated and
            // releases ownership itself, so nothing else can claim it early.
            lifecycle.retireStartRun()
            startup.cancel()
            state = .stopping
            return
        }
        guard lifecycle.state != .idle else { return }
        let activeSession = transcriptionSession
        transcriptionSession = nil
        stopWasCancelled = stoppingSession != nil
        activeSession?.cancel()
        stoppingSession?.cancel()
        // A stopping session retains ownership until its suspended drain returns.
        isRunning = false
        finishPresentation()
        startTime = nil
        if liveActivitiesEnabled() {
            activityManager.endActivity()
        }
        partialText = ""
        confidence = nil
        wordCount = 0
        sharedState.clear()
        sharedState.clearRecordingState()
        if lifecycle.beginStopping() {
            state = lifecycle.state
            let runID = ownedRunID
            Task { @MainActor [self] in
                await activeSession?.awaitCancellationSettled()
                guard ownedRunID == runID else { return }
                lifecycle.finishStopping()
                releaseOwnership()
                state = lifecycle.state
            }
        }
    }
}

// The provider start itself lives in an extension so the coordinator's own
// body stays readable; `start` above owns the ownership claim, the
// single-flight guard and the run identity.
@MainActor
private extension TranscriberCoordinator {
    /// Batch runs need usable credentials before anything is published, so a
    /// missing key settles the run here rather than leaving it in preparation.
    func requireBatchCredentialsIfNeeded(runID: UUID) throws {
        let settings = AppSettings.shared
        guard settings.transcriptionMode == .batch else { return }
        do {
            try settings.requireAvailableCredentials(for: currentModel, purpose: .batchTranscription)
        } catch {
            // Nothing has been published yet beyond the run itself, so the
            // run settles here rather than sitting in preparation forever.
            finishStartupDiagnostics(runID: runID, error: error)
            finishPresentation()
            throw error
        }
    }

    // swiftlint:disable:next function_body_length
    func startOwnedRun(
        _ runID: UUID,
        preRollBuffers: [AVAudioPCMBuffer],
        analyzerFallbackAllowed: Bool
    ) async throws {
        // Wait for the initial keychain load so auto-start on a cold launch
        // doesn't read empty API keys and fall back to Apple Speech.
        await ensureKeysLoaded()
        try checkStart(runID)
        diagnostics.note(.stage(.credentialsReady), run: runID)
        let settings = AppSettings.shared
        captureStopNotice = nil
        recordingWarning = nil
        currentModel = settings.transcriptionMode == .batch
            ? settings.batchTranscriptionModel
            : settings.selectedModel
        requestDiagnostics.admit(IOSRequestDiagnosticProjection.foreground(modelID: currentModel), run: runID)
        try requireBatchCredentialsIfNeeded(runID: runID)
        partialText = ""
        confidence = nil
        wordCount = 0
        lastSharedStateWriteAt = .distantPast
        startTime = Date()
        sharedState.clear()

        let localeIdentifier = TranscriptionLanguageCatalog.localeIdentifier(
            for: settings.preferredLocaleIdentifier
        )
        let usesBatch = settings.transcriptionMode == .batch
        let connectivity = self.networkSnapshot()
        let capability = OfflineCaptureRouting.needsLocalCapability(
            usesBatch: usesBatch,
            requestedModelID: self.currentModel,
            connectivity: connectivity
        ) ? self.localRecognitionCapability(localeIdentifier) : .unknown
        let offlineDecision = OfflineCaptureRouting.decide(
            usesBatch: usesBatch,
            requestedModelID: self.currentModel,
            binding: .ordinary,
            connectivity: connectivity,
            localCapability: capability
        )
        let strictOnDeviceRecognition: Bool
        switch offlineDecision {
        case .use(let route):
            self.offlineIntendedModel = route.notice == nil ? nil : self.currentModel
            self.currentModel = route.modelID
            self.recordingWarning = route.notice
            strictOnDeviceRecognition = route.requiresStrictOnDeviceRecognition
        case .refuse:
            throw iOSTranscriptionError.offlineLocalRecognitionUnavailable
        }

        if settings.transcriptionMode == .streaming {
            let route = LiveTranscriptionRouting.route(for: currentModel)
            currentModel = LiveTranscriptionRouting.resolvedModelID(
                for: currentModel,
                apiKey: route.map { settings.liveAPIKey(for: $0) }
            )
        }

        // Start Live Activity (if enabled). It arms rather than records: the
        // presentation gate promotes it once this run has proven its input.
        if liveActivitiesEnabled() {
            activityManager.startActivity(provider: modelDisplayName, initialStatus: .arming)
        }

        #if DEBUG && targetEnvironment(simulator)
        if let transcript = sharedState.simulatorValidationTranscript {
            try checkStart(runID)
            // A synthetic transcript is not observed microphone input, but this
            // DEBUG-only simulator stub has no input tap at all. Resolve the
            // gate explicitly so the harness never sits in preparation.
            presentation.noteBackendStarted(run: runID)
            notePresentation(presentation.noteInputObserved(run: runID))
            noteSimulatorStubStartup(runID: runID)
            handlePartialResult(text: transcript, isFinal: true)
            return
        }
        #endif

        let mode: IOSTranscriptionSession.Mode = settings.transcriptionMode == .batch
            ? .batch(retainRecording: true)
            : .streaming
        // Both seams are honoured: `makeSession` (#936) injects any recording
        // session, while `sessionFactory` remains the concrete test seam.
        let session: any IOSRecordingSession = try makeSession?()
            ?? sessionFactory?()
            ?? IOSTranscriptionSession(
            modelID: currentModel,
            mode: mode,
            language: settings.preferredModelLanguage,
            audioSessionManager: audioSessionManager,
            batchAPIKey: settings.batchAPIKey,
            liveAPIKey: settings.liveAPIKey(for:),
            transcriptionKeywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords),
            requiresStrictOnDeviceRecognition: strictOnDeviceRecognition
        )
        startingSession = session
        bindCallbacks(to: session, runID: runID)
        bindFirstInput(session: session, runID: runID)
        bindStartupDiagnostics(session: session, runID: runID)
        // Cancellation is owned by exactly this run and exactly this session;
        // a late installation is cancelled immediately and cannot attach to a
        // replacement run.
        guard lifecycle.installStartCancellation(for: runID, cancel: { session.cancel() }) else {
            throw CancellationError()
        }
        requestDiagnostics.observe(
            session.resolution, run: runID, defaultSession: makeSession == nil && sessionFactory == nil
        )
        try await session.start(
            preRollBuffers: preRollBuffers,
            analyzerFallbackAllowed: analyzerFallbackAllowed
        )
        try checkStart(runID)
        diagnostics.note(.stage(.sessionStarted), run: runID)
        // Activation follows RecordingStartupOperation's final cancellation check in start().
        transcriptionSession = session
    }

}

// MARK: - Truthful capture presentation (issue #983)

private extension TranscriberCoordinator {
    /// Routes this run's own first live buffer into the presentation gate.
    /// The buffer can arrive while `start()` is still suspended, which is why
    /// this reads the run identity rather than the activated session.
    func bindFirstInput(session: any IOSRecordingSession, runID: UUID) {
        session.onFirstInputBuffer = { [weak self, weak session] in
            guard let self, let session, self.acceptsCallback(runID, session: session) else { return }
            self.notePresentation(self.presentation.noteInputObserved(run: runID))
        }
    }

    /// Publishes the one arming → recording transition, and only that one.
    func notePresentation(_ promoted: Bool) {
        guard promoted else { return }
        if liveActivitiesEnabled() {
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
    /// Whether a provider error should finalise through the owner rather than
    /// surface as a bare failure.
    static func requiresControlledStop(_ error: Error) -> Bool {
        // Interruption and microphone change both finalise through the owner
        // (#936); a pre-ready startup overflow stops once (#949).
        if (error as? iOSTranscriptionError)?.endsCapture == true { return true }
        if case OpenAIRealtimeError.preReadyAudioOverflow = error { return true }
        return false
    }

    /// Publishes a nonfatal capture or writer loss for this run (#950).
    func handleRecordingWarning(_ message: String) {
        recordingWarning = message
    }

    /// Publishes a mid-session failure and mirrors it into the Live Activity.
    func handleError(_ error: Error) {
        // An audio interruption is a controlled stop (issue #936): a notice,
        // never an error banner or a Live Activity failure.
        if (error as? iOSTranscriptionError)?.isControlledInterruption == true {
            captureStopNotice = error.localizedDescription
            return
        }
        issueFailureSnapshot = requestDiagnostics.freezeFailure(.init(stage: .request), run: ownedRunID)
            ?? IOSIssueReporter.failedRequest()
        self.error = error
        if liveActivitiesEnabled() {
            activityManager.reportError(error.localizedDescription)
        }
    }

    /// Presentation only: the transcript is delivered either way. A partial can
    /// arrive from pre-roll before this run has seen its own input, and it must
    /// not announce active capture.
    func publishTranscriptActivity(text: String) {
        guard liveActivitiesEnabled() else { return }
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
    /// Opens a run: the lifecycle's identity is shared by the presentation
    /// gate and the startup measurement, so neither can attribute work to
    /// another run.
    func beginRun(_ runID: UUID, entry: StartupEntry?) {
        requestDiagnostics.begin(runID)
        presentationRunID = runID
        presentation.begin(run: runID)
        diagnostics.begin(run: runID, entry: entry, localOrigin: .coordinator)
    }

    /// Wires this run to the session's existing observation boundary, and
    /// labels the backend when routing already settled it.
    func bindStartupDiagnostics(session: any IOSRecordingSession, runID: UUID) {
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
        if error is CancellationError || Task.isCancelled {
            requestDiagnostics.discardFailure(runID)
        } else {
            // Still owned; freeze before presentation/run teardown clears state.
            requestDiagnostics.freezeFailure(.init(), run: runID)
        }
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
#endif
