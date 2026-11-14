#if os(iOS)
import AVFoundation
import Combine
import SpeakCore
import UIKit

/// Foreground recording coordinator: it publishes the run's state.
/// ``ForegroundRunOwner`` decides which run and session own capture,
/// ``ForegroundRunObservation`` what is presented and measured,
/// ``ForegroundRunLauncher`` which route and session a run starts, and
/// ``ForegroundLiveActivity`` what the lock screen shows.
@MainActor
final class TranscriberCoordinator: ObservableObject {
    /// Mirrored from the run owner after every transition (#943). `isRunning`
    /// keeps its recording-only meaning; `starting` and `stopping` let the
    /// button and the auto-start stay on one action.
    @Published private(set) var state: RecordingServiceState = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var shown = ForegroundShownTranscript()
    var partialText: String { shown.text }
    var wordCount: Int { shown.wordCount }
    var confidence: Double? { shown.confidence }
    @Published private(set) var error: Error? {
        didSet { if error == nil { issueFailureSnapshot = IOSIssueReporter.failedRequest() } }
    }
    private(set) var issueFailureSnapshot = IOSIssueReporter.failedRequest()
    @Published private(set) var recordingWarning: String?
    @Published private(set) var currentModel: String = AppleLocalModels.preferredSpeechModelID
    @Published private(set) var captureStopNotice: String?

    var audioSessionManager: AudioSessionManager { launcher.audioSessionManager }
    private var mirror: ForegroundTranscriptMirror
    private let finalisation: ForegroundCaptureFinalisation
    private let launcher: ForegroundRunLauncher
    private let owner: ForegroundRunOwner
    private let observation: ForegroundRunObservation
    private let liveActivity: ForegroundLiveActivity
    private let headlessState: @MainActor () -> RecordingServiceState

    var onCaptureDisruption: (() async -> Void)?
    /// Lets an owner presenting on this coordinator's behalf (hands-free) re-publish.
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
        self.mirror = ForegroundTranscriptMirror(sharedState: sharedState)
        self.finalisation = ForegroundCaptureFinalisation(sharedState: sharedState, historyManager: historyManager)
        let owner = ForegroundRunOwner(ownership: ownership ?? .shared) { observation.retire($0) }
        self.launcher = ForegroundRunLauncher(
            owner: owner, observation: observation, audioSessionManager: AudioSessionManager(),
            ensureKeysLoaded: ensureKeysLoaded, networkSnapshot: networkSnapshot,
            localRecognitionCapability: localRecognitionCapability, sessionFactory: sessionFactory
        )
        self.observation = observation
        self.owner = owner
        self.liveActivity = ForegroundLiveActivity(manager: .shared, isEnabled: liveActivitiesEnabled)
        self.headlessState = headlessState
    }

    func issueSnapshot(failedStart run: UUID?) -> IOSIssueReportSnapshot { observation.failedStartSnapshot(for: run) }

    var isPresentingCapture: Bool { observation.isPresentingCapture }

    /// A noticed controlled interruption, else the engine changed.
    var captureDisruptionReason: iOSTranscriptionError { captureStopNotice == nil ? .microphoneChanged : .interrupted }

    var modelDisplayName: String {
        ModelCatalog.transcriptionDisplayName(
            for: currentModel,
            isBatch: owner.activeSession?.isBatch ?? (AppSettings.shared.transcriptionMode == .batch)
        )
    }

    private var elapsedSeconds: Int { mirror.elapsedSeconds }

    /// From the claim before the first suspension until the run activates or
    /// unwinds, so recording toggles stay on one action.
    var isStartingRecording: Bool { owner.phase == .starting }

    /// Starts an owned foreground run. Ownership is claimed synchronously,
    /// before any suspension, and is what the Control and intent start guards
    /// read; a duplicate start throws rather than allocating a second session.
    /// A cancelled start throws `CancellationError` and never activates.
    ///
    /// - Parameter entry: the earliest app-code entry observed, or `nil` to
    ///   time the coordinator's own entry (#972).
    /// - Parameter handle: binds a hands-free owner's later stop/cancel to
    ///   this run, so a rejected start cannot act on another recording.
    func start(
        preRollBuffers: [AVAudioPCMBuffer] = [], analyzerFallbackAllowed: Bool = true,
        entry: StartupEntry? = nil, handle: ForegroundCaptureHandle? = nil
    ) async throws {
        try Task.checkCancellation()
        // No suspension between checking the headless service and claiming the foreground.
        guard headlessState() == .idle, let runID = owner.claim(binding: handle) else {
            throw ForegroundRunOwner.BusyError()
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
            state = owner.phase
            isRunning = true
            mirror.markRecording()
            if owner.activeSession != nil {
                // The tap may already have delivered; the simulator stub resolved both halves.
                notePresentation(observation.noteBackendStarted(runID))
                observation.noteStarted(runID)
            }
        } catch {
            throw await unwindStart(runID, after: error)
        }
    }

    /// Settles a failed or cancelled start and returns what the caller sees.
    /// Intentional cancellation has no provider error, result or History entry.
    private func unwindStart(_ runID: UUID, after error: Error) async -> Error {
        var cancelled = !owner.isCurrentStartRun(runID) || error is CancellationError || Task.isCancelled
        // Cancels exactly this run's session and holds ownership until its
        // cleanup settles, so a replacement can never overlap it.
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

    /// Hands-free stop bound to its start's run; a stale handle returns an
    /// empty result. A non-nil `rearmHandsFree` marks the hands-free lane and
    /// decides whether the Live Activity rearms (#942/#1040).
    func stop(
        handle: ForegroundCaptureHandle, rearmHandsFree: @escaping @MainActor () -> Bool
    ) async -> TranscriptionResult {
        guard owner.owns(handle) else { return emptyResult() }
        return await stop(rearmHandsFree: rearmHandsFree)
    }

    func cancel(handle: ForegroundCaptureHandle) {
        guard owner.owns(handle) else { return }
        cancel()
    }

    /// Cancels a pending startup (retiring it before suspending, so nothing
    /// that runs meanwhile looks like a replacement start) and waits for it.
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
        // A second stop while this one drains must not produce a second result or History entry.
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

        var result: TranscriptionResult?
        if let session = owner.takeForStop() {
            result = await stop(session: session, duration: duration, rearmHandsFree: rearmHandsFree)
        }
        mirror.finish()
        return result ?? liveResult(confidence: nil, duration: duration)
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
        // A retired run's loss notice goes with it, even from an idle coordinator (#950).
        recordingWarning = nil
        let outcome = owner.cancel()
        guard case .cancelled(let activeSession) = outcome else {
            if case .retiredStart = outcome { state = .stopping }
            return
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

// MARK: - Session callbacks, finalisation and starting

private extension TranscriberCoordinator {
    /// Binds this run's provider callbacks through the run owner (#943).
    func bindCallbacks(to session: any IOSRecordingSession, runID: UUID) {
        owner.bind(session, run: runID, to: .init(
            partial: { [weak self] text, isFinal, session in
                guard let self else { return }
                self.observation.noteFirstLivePartial(text: text, isFinal: isFinal, run: runID)
                self.handlePartialResult(text: text, isFinal: isFinal)
                self.shown.confidence = session.confidence
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
        guard ForegroundCaptureFinalisation.requiresControlledStop(error) else { return }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session, self.owner.activeSession === session, self.isRunning else { return }
            if let onCaptureDisruption = self.onCaptureDisruption {
                await onCaptureDisruption()
            } else {
                _ = await self.stop()
            }
        }
    }

    func handlePartialResult(text: String, isFinal: Bool) {
        // Throttled; the full transcript is committed once more at stop.
        shown.show(partial: text, words: mirror.admit(text))
        liveActivity.publishTranscript(
            text, finalising: owner.phase == .stopping, presentingCapture: observation.isPresentingCapture,
            words: wordCount, seconds: elapsedSeconds
        )
    }

    func stop(
        session: any IOSRecordingSession, duration: Int, rearmHandsFree: (@MainActor () -> Bool)?
    ) async -> TranscriptionResult? {
        defer { if owner.endStop(of: session) { recordingWarning = session.recordingLossSummary } }
        let settlement = await ForegroundCaptureFinalisation.settle(
            session, handsFree: rearmHandsFree != nil,
            stillOwned: { owner.stillOwnsStop(of: session) },
            shown: { liveResult(confidence: confidence, duration: duration) },
            onFailure: { error in
                if !(error is CancellationError) { handleError(error) }
                return rearmHandsFree != nil || captureStopNotice != nil // Explicit Cancel clears content.
            }
        )
        guard case .finished(let finished) = settlement else { return settlement.discarded }
        let result = finished.replacingText(IOSLearnedCorrections.shared.apply(to: finished.text))
        shown.show(final: result.text)
        liveActivity.complete(
            result, words: wordCount, seconds: duration, rearmHandsFree: rearmHandsFree, stopNotice: captureStopNotice
        )
        await finalisation.deliver(
            result, from: session, model: currentModel, error: error, offlineIntendedModel: offlineIntendedModel
        )
        return result
    }

    func liveResult(confidence: Double?, duration: Int) -> TranscriptionResult {
        shown.result(confidence: confidence, duration: duration, model: currentModel)
    }

    func clearShownTranscript() { shown = ForegroundShownTranscript() }

    func emptyResult() -> TranscriptionResult { .shown("", confidence: nil, duration: 0, model: currentModel) }

    func startOwnedRun(
        _ runID: UUID, preRollBuffers: [AVAudioPCMBuffer], analyzerFallbackAllowed: Bool
    ) async throws {
        let request = try await launcher.request(for: runID)
        captureStopNotice = nil
        recordingWarning = nil
        currentModel = request.modelID
        observation.admitRequest(modelID: currentModel, run: runID)
        do {
            try launcher.requireCredentials(for: request)
        } catch {
            // A missing key settles the run here rather than leaving it in preparation.
            observation.finishStartup(runID, error: error)
            finishPresentation()
            throw error
        }
        clearShownTranscript()
        mirror.begin()

        let route = try launcher.route(for: request)
        offlineIntendedModel = route.offlineIntendedModelID
        currentModel = route.modelID
        recordingWarning = route.notice
        liveActivity.arm(provider: modelDisplayName)

        #if DEBUG && targetEnvironment(simulator)
        if let transcript = mirror.sharedState.simulatorValidationTranscript {
            try owner.checkStart(runID)
            // The stub has no input tap: resolve the gate so the harness never sits in preparation.
            observation.noteBackendStarted(runID)
            notePresentation(observation.noteInputObserved(runID))
            observation.noteSimulatorStub(runID)
            handlePartialResult(text: transcript, isFinal: true)
            return
        }
        #endif

        let session = try makeSession?() ?? launcher.makeSession(route, request: request)
        bindCallbacks(to: session, runID: runID)
        try await launcher.start(
            session, run: runID, defaultSession: makeSession == nil,
            preRollBuffers: preRollBuffers, analyzerFallbackAllowed: analyzerFallbackAllowed
        )
    }
}

// MARK: - Presentation

extension TranscriberCoordinator {
    /// Publishes a nonfatal capture or writer loss for this run (#950).
    func handleRecordingWarning(_ message: String) { recordingWarning = message }

    /// Publishes a mid-session failure and mirrors it into the Live Activity.
    /// An audio interruption is a controlled stop (#936): a notice only.
    func handleError(_ error: Error) {
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

    private func finishPresentation() {
        guard observation.finishPresentation() else { return }
        onCapturePresentationChanged?()
    }
}
#endif
