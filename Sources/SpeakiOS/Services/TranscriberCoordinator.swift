#if os(iOS)
import AVFoundation
import Combine
import SpeakCore
import UIKit

/// Foreground recording coordinator backed by the shared iOS transcription factory.
/// Integrates with Live Activity for lock screen presence.
///
/// It publishes the run's state. ``ForegroundRunOwner`` decides which run and
/// session own capture, ``ForegroundRunObservation`` what is presented and
/// measured for that run, ``ForegroundCaptureRoute`` which model it records
/// with, and ``ForegroundLiveActivity`` what the lock screen shows.
@MainActor
final class TranscriberCoordinator: ObservableObject {
    private enum LifecycleError: LocalizedError {
        case sessionBusy

        var errorDescription: String? {
            "A transcription is already starting, recording or finalising."
        }
    }

    /// The foreground lifecycle, mirrored from the run owner after every
    /// transition (#943). `isRunning` keeps its recording-only meaning for
    /// existing observers; `starting` and `stopping` are visible here so the
    /// button and the auto-start can stay on one action.
    @Published private(set) var state: RecordingServiceState = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var partialText = ""
    @Published private(set) var error: Error? {
        didSet { if error == nil { issueFailureSnapshot = IOSIssueReporter.failedRequest() } }
    }
    private(set) var issueFailureSnapshot = IOSIssueReporter.failedRequest()

    func issueSnapshot(failedStart run: UUID?) -> IOSIssueReportSnapshot {
        observation.failedStartSnapshot(for: run)
    }
    @Published private(set) var recordingWarning: String?
    @Published private(set) var currentModel: String = AppleLocalModels.preferredSpeechModelID
    @Published private(set) var confidence: Double?
    @Published private(set) var wordCount: Int = 0
    @Published private(set) var captureStopNotice: String?

    let audioSessionManager: AudioSessionManager
    private var mirror: ForegroundTranscriptMirror
    private let finalisation: ForegroundCaptureFinalisation
    private let sessionFactory: (() throws -> IOSTranscriptionSession)?
    private let owner: ForegroundRunOwner
    private let observation: ForegroundRunObservation
    private let liveActivity: ForegroundLiveActivity
    private let ensureKeysLoaded: @MainActor () async -> Void
    private let headlessState: @MainActor () -> RecordingServiceState
    private let networkSnapshot: CaptureNetworkPathMonitor.SnapshotProvider
    private let localRecognitionCapability: @MainActor (String) -> AppleLocalRecognitionCapability

    var onCaptureDisruption: (() async -> Void)?
    /// Raised when this coordinator's capture presentation changes, so an
    /// owner presenting on its behalf (hands-free) can re-publish.
    var onCapturePresentationChanged: (() -> Void)?
    var makeSession: (() throws -> any IOSRecordingSession)?
    /// Queues an offline on-device capture for a cloud upgrade (issue #999).
    var tagOfflineCapture: (iOSHistoryItem, UUID, String) -> Void {
        get { finalisation.tagOfflineCapture }
        set { finalisation.tagOfflineCapture = newValue }
    }
    /// The cloud model this run would have used had the network been up.
    private var offlineIntendedModel: String?

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
        let observation = ForegroundRunObservation()
        self.audioSessionManager = AudioSessionManager()
        self.mirror = ForegroundTranscriptMirror(sharedState: sharedState)
        self.finalisation = ForegroundCaptureFinalisation(sharedState: sharedState, historyManager: historyManager)
        self.sessionFactory = sessionFactory
        self.observation = observation
        self.owner = ForegroundRunOwner(ownership: ownership ?? .shared) { observation.retire($0) }
        self.liveActivity = ForegroundLiveActivity(manager: .shared, isEnabled: liveActivitiesEnabled)
        self.ensureKeysLoaded = ensureKeysLoaded
        self.headlessState = headlessState
        self.networkSnapshot = networkSnapshot
        self.localRecognitionCapability = localRecognitionCapability
    }

    /// Whether active-capture presentation may be shown for the current run.
    var isPresentingCapture: Bool { observation.isPresentingCapture }

    /// Why the capture in flight is being finished by its owner: a controlled
    /// audio interruption when one has been noticed, else the engine changed.
    var captureDisruptionReason: iOSTranscriptionError {
        captureStopNotice == nil ? .microphoneChanged : .interrupted
    }

    var modelDisplayName: String {
        ModelCatalog.transcriptionDisplayName(
            for: currentModel,
            isBatch: owner.activeSession?.isBatch
                ?? (AppSettings.shared.transcriptionMode == .batch)
        )
    }

    private var elapsedSeconds: Int { mirror.elapsedSeconds }

    /// True while a start is in flight — from the claim before the first
    /// suspension until that run has activated or unwound. UI that toggles
    /// recording uses this to stay on one action until startup settles.
    var isStartingRecording: Bool { owner.phase == .starting }

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
        // No suspension between checking the headless service and claiming the foreground.
        guard headlessState() == .idle, let runID = owner.claim(binding: handle) else {
            throw LifecycleError.sessionBusy
        }
        state = .starting
        error = nil
        observation.begin(runID, entry: entry)
        do {
            try await owner.runStartup { [self] in
                try await startOwnedRun(runID, preRollBuffers: preRollBuffers,
                                        analyzerFallbackAllowed: analyzerFallbackAllowed)
            }
            try owner.checkStart(runID)
            try owner.activate(runID)
            markRecordingStarted()
            if owner.activeSession != nil {
                // The tap can deliver before `start()` returns, so this may be
                // the second half of the pair rather than the first. The
                // simulator stub resolved both halves itself.
                notePresentation(observation.noteBackendStarted(runID))
                observation.noteStarted(runID)
            }
        } catch {
            throw await unwindStart(runID, after: error)
        }
    }

    /// Settles a start that failed or was cancelled, and returns what the
    /// caller sees. Intentional cancellation is the user getting what they
    /// asked for: no provider error, no result, no History entry.
    private func unwindStart(_ runID: UUID, after error: Error) async -> Error {
        var cancelled = !owner.isCurrentStartRun(runID) || error is CancellationError || Task.isCancelled
        // Retiring the run fires the cancellation installed for exactly the
        // session this run allocated; ownership is held until that provider's
        // own cleanup has settled, so a replacement can never overlap it.
        await owner.retireStart()
        cancelled = cancelled || state == .stopping || Task.isCancelled
        clearShownTranscript()
        observation.finishStartup(runID, error: cancelled ? CancellationError() : error)
        finishPresentation()
        mirror.clear()
        liveActivity.end()
        owner.finishStartUnwind()
        state = owner.phase
        guard !cancelled else {
            self.error = nil
            return CancellationError()
        }
        return error
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
        guard owner.owns(handle) else { return emptyResult() }
        return await stop(rearmHandsFree: rearmHandsFree)
    }

    func cancel(handle: ForegroundCaptureHandle) {
        guard owner.owns(handle) else { return }
        cancel()
    }

    /// Cancels a pending startup and waits for it to unwind. Retire before
    /// suspending, so nothing that runs while this waits can be mistaken for
    /// a replacement start.
    func cancelStartup() async {
        guard owner.phase == .starting else { return }
        cancel()
        await owner.awaitStartSettled()
    }

    func stop(rearmHandsFree: (@MainActor () -> Bool)? = nil) async -> TranscriptionResult {
        if owner.phase == .starting {
            await cancelStartup()
            return emptyResult()
        }
        // Reentrancy guard: a second stop while this one drains has nothing
        // left to act on, and must not produce a second result or History entry.
        guard owner.beginStopping() else { return emptyResult() }
        state = owner.phase
        defer {
            owner.finishStopping()
            state = owner.phase
        }
        isRunning = false
        finishPresentation()
        mirror.endRecording()
        let duration = elapsedSeconds
        liveActivity.update(.finalising, snippet: "Finalising transcript…", words: wordCount, seconds: duration)

        if let session = owner.takeForStop(),
           let result = await stop(session: session, duration: duration, rearmHandsFree: rearmHandsFree) {
            return result
        }

        mirror.finish()
        return liveResult(confidence: nil, duration: duration)
    }

    /// Cancels and waits until this owner has released — startup unwound, or
    /// the cancelled provider's cleanup settled.
    func cancelAndWait() async {
        guard let runID = owner.ownedRunID else { return }
        cancel()
        guard owner.ownedRunID == runID else { return }
        await owner.waitForRelease()
    }

    func cancel() {
        // A retired run's loss notice goes with it, whatever state it is in —
        // including an idle coordinator still showing the previous run's (#950).
        recordingWarning = nil
        let activeSession: (any IOSRecordingSession)?
        switch owner.cancel() {
        case .idle:
            return
        case .retiredStart:
            state = .stopping
            return
        case .cancelled(let settling):
            activeSession = settling
        }
        isRunning = false
        finishPresentation()
        liveActivity.end()
        clearShownTranscript()
        mirror.clear()
        if owner.settleCancellation(of: activeSession, then: { [self] in state = owner.phase }) {
            state = owner.phase
        }
    }
}

// MARK: - Session callbacks

private extension TranscriberCoordinator {
    /// Binds this run's provider callbacks through the run owner (#943).
    func bindCallbacks(to session: any IOSRecordingSession, runID: UUID) {
        owner.bind(session, run: runID, to: .init(
            partial: { [weak self] text, isFinal, session in
                guard let self else { return }
                self.observation.noteFirstLivePartial(text: text, isFinal: isFinal, run: runID)
                self.handlePartialResult(text: text, isFinal: isFinal)
                self.confidence = session.confidence
            },
            warning: { [weak self] in self?.handleRecordingWarning($0) },
            failure: { [weak self] error, session in self?.handleSessionFailure(error, from: session) },
            firstInput: { [weak self] in
                guard let self else { return }
                self.notePresentation(self.observation.noteInputObserved(runID))
            }
        ))
        observation.bindStartup(of: session, run: runID)
    }

    /// A mid-capture failure; one that ends capture finalises through the owner.
    func handleSessionFailure(_ error: Error, from session: any IOSRecordingSession) {
        handleError(error)
        guard Self.requiresControlledStop(error) else { return }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session, self.owner.activeSession === session, self.isRunning else { return }
            if let onCaptureDisruption = self.onCaptureDisruption {
                await onCaptureDisruption()
            } else {
                _ = await self.stop()
            }
        }
    }

    func markRecordingStarted() {
        state = owner.phase
        isRunning = true
        mirror.markRecording()
    }

    func handlePartialResult(text: String, isFinal: Bool) {
        partialText = text

        // App Group writes and word counting are O(n) per partial; throttle
        // them to ~1/s (matching the Live Activity manager's own throttle).
        // The full transcript is committed once more at stop.
        if mirror.admit(text) {
            wordCount = text.split(separator: " ").count
        }

        if owner.phase == .stopping {
            // A final partial delivered by the drain describes finalisation,
            // never active capture.
            liveActivity.update(.finalising, snippet: text, words: wordCount, seconds: elapsedSeconds)
            return
        }
        liveActivity.publishTranscript(
            text, presentingCapture: observation.isPresentingCapture, words: wordCount, seconds: elapsedSeconds
        )
    }
}

// MARK: - Finalisation

private extension TranscriberCoordinator {
    func stop(
        session: any IOSRecordingSession,
        duration: Int,
        rearmHandsFree: (@MainActor () -> Bool)?
    ) async -> TranscriptionResult? {
        defer {
            if owner.endStop(of: session) { recordingWarning = session.recordingLossSummary }
        }
        let settlement = await ForegroundCaptureFinalisation.settle(
            session, handsFree: rearmHandsFree != nil,
            stillOwned: { owner.stillOwnsStop(of: session) },
            shown: { liveResult(confidence: confidence, duration: duration) },
            onFailure: { error in
                if !(error is CancellationError) { handleError(error) }
                // Explicit Cancel still clears content.
                return rearmHandsFree != nil || captureStopNotice != nil
            }
        )
        let result: TranscriptionResult
        switch settlement {
        case .abandoned:
            return nil
        case .discarded(let discarded):
            mirror.finish()
            return discarded
        case .finished(let finished):
            result = finished
        }
        partialText = result.text
        wordCount = result.text.split(whereSeparator: \.isWhitespace).count
        liveActivity.complete(
            result, words: wordCount, seconds: duration,
            rearmHandsFree: rearmHandsFree, stopNotice: captureStopNotice
        )
        let warning = session.recordingLossSummary
        await finalisation.deliver(
            result, model: currentModel,
            errorMessage: warning.map { [$0, error?.localizedDescription].compactMap { $0 }.joined(separator: " ") },
            offlineIntendedModel: offlineIntendedModel, recordingID: session.safetyRecordingID
        )
        mirror.finish()
        return result
    }

    /// The text shown so far, as the run's result.
    func liveResult(confidence: Double?, duration: Int) -> TranscriptionResult {
        TranscriptionResult(text: partialText, segments: [], confidence: confidence, duration: TimeInterval(duration),
                            modelIdentifier: currentModel, cost: nil, rawPayload: nil, debugInfo: nil)
    }

    func clearShownTranscript() {
        partialText = ""
        wordCount = 0
        confidence = nil
    }

    func emptyResult() -> TranscriptionResult {
        TranscriptionResult(text: "", segments: [], confidence: nil, duration: 0,
                            modelIdentifier: currentModel, cost: nil, rawPayload: nil, debugInfo: nil)
    }
}

// MARK: - Starting the provider

private extension TranscriberCoordinator {
    /// Batch runs need usable credentials before anything is published, so a
    /// missing key settles the run here rather than leaving it in preparation.
    func requireBatchCredentialsIfNeeded(runID: UUID) throws {
        let settings = AppSettings.shared
        guard settings.transcriptionMode == .batch else { return }
        do {
            try settings.requireAvailableCredentials(for: currentModel, purpose: .batchTranscription)
        } catch {
            observation.finishStartup(runID, error: error)
            finishPresentation()
            throw error
        }
    }

    func startOwnedRun(
        _ runID: UUID,
        preRollBuffers: [AVAudioPCMBuffer],
        analyzerFallbackAllowed: Bool
    ) async throws {
        // Wait for the initial keychain load so auto-start on a cold launch
        // doesn't read empty API keys and fall back to Apple Speech.
        await ensureKeysLoaded()
        try owner.checkStart(runID)
        observation.note(.stage(.credentialsReady), run: runID)
        let settings = AppSettings.shared
        let usesBatch = settings.transcriptionMode == .batch
        captureStopNotice = nil
        recordingWarning = nil
        currentModel = usesBatch ? settings.batchTranscriptionModel : settings.selectedModel
        observation.admitRequest(modelID: currentModel, run: runID)
        try requireBatchCredentialsIfNeeded(runID: runID)
        clearShownTranscript()
        mirror.begin()

        let route = try ForegroundCaptureRoute.resolve(
            settings: settings, requestedModelID: currentModel, usesBatch: usesBatch,
            connectivity: networkSnapshot(), localCapability: localRecognitionCapability
        )
        offlineIntendedModel = route.offlineIntendedModelID
        currentModel = route.modelID
        recordingWarning = route.notice
        liveActivity.arm(provider: modelDisplayName)

        #if DEBUG && targetEnvironment(simulator)
        if let transcript = mirror.sharedState.simulatorValidationTranscript {
            try owner.checkStart(runID)
            // A synthetic transcript is not observed microphone input, but this
            // DEBUG-only simulator stub has no input tap at all. Resolve the
            // gate explicitly so the harness never sits in preparation.
            observation.noteBackendStarted(runID)
            notePresentation(observation.noteInputObserved(runID))
            observation.noteSimulatorStub(runID)
            handlePartialResult(text: transcript, isFinal: true)
            return
        }
        #endif

        // Both seams are honoured: `makeSession` (#936) injects any recording
        // session, while `sessionFactory` remains the concrete test seam.
        let session: any IOSRecordingSession = try makeSession?() ?? sessionFactory?()
            ?? route.makeSession(usesBatch: usesBatch, settings: settings, audioSessionManager: audioSessionManager)
        bindCallbacks(to: session, runID: runID)
        try owner.adoptStarting(session, run: runID)
        observation.observe(session.resolution, run: runID, defaultSession: makeSession == nil && sessionFactory == nil)
        try await session.start(
            preRollBuffers: preRollBuffers,
            analyzerFallbackAllowed: analyzerFallbackAllowed
        )
        try owner.checkStart(runID)
        observation.note(.stage(.sessionStarted), run: runID)
        // Activation follows RecordingStartupOperation's final cancellation check in start().
        owner.noteStarted(session)
    }
}

// MARK: - Presentation

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
        issueFailureSnapshot = observation.freezeRequestFailure(run: owner.ownedRunID)
            ?? IOSIssueReporter.failedRequest()
        self.error = error
        liveActivity.reportError(error)
    }

    /// Publishes the one arming → recording transition, and only that one.
    private func notePresentation(_ promoted: Bool) {
        guard promoted else { return }
        liveActivity.update(.recording, snippet: partialText, words: wordCount, seconds: elapsedSeconds)
        onCapturePresentationChanged?()
    }

    /// Ends the run's presentation: stop, cancel, or a failed start.
    private func finishPresentation() {
        guard observation.finishPresentation() else { return }
        onCapturePresentationChanged?()
    }
}
#endif
