#if os(iOS)
import AVFoundation
import Foundation
import Speech
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "iOSLiveTranscriber")

// swiftlint:disable file_length
/// iOS-native live transcription using Apple Speech framework.
///
/// The transcriber owns one capture at a time and its published state. Its
/// collaborators each own one part of that capture:
/// - ``LiveCaptureInput``: the engine, the input tap and the disruption guard;
/// - ``AppleSpeechCaptureTap``: the tap buffers and the serial queue that
///   feeds the recogniser and the safety recording;
/// - ``AppleSpeechAnalyzerCapture`` (iOS 26): the SpeechAnalyzer session;
/// - ``LegacyAppleRecognitionController``: the `SFSpeechRecognizer` task,
///   its restarts, its bounded Stop wait and the transcript assembly.
@MainActor
public final class iOSLiveTranscriber: ObservableObject {
    // MARK: - Published State

    @Published private(set) public var isRunning = false
    @Published private(set) public var partialText = ""
    @Published private(set) public var isFinal = false
    @Published private(set) public var confidence: Double?
    @Published private(set) public var error: Error?

    // MARK: - Configuration

    public var language: String = Locale.current.identifier
    public var preferOnDevice: Bool {
        get { legacyRecognition.preferOnDevice }
        set { legacyRecognition.preferOnDevice = newValue }
    }
    public var modelID: String = AppleLocalModels.preferredSpeechModelID
    /// Hard privacy requirement for routes that promise local processing.
    /// Unlike `preferOnDevice`, this may never fall through to Apple servers.
    var requiresStrictOnDeviceRecognition: Bool {
        get { legacyRecognition.requiresStrictOnDeviceRecognition }
        set { legacyRecognition.requiresStrictOnDeviceRecognition = newValue }
    }

    // MARK: - Callbacks

    public var onPartialResult: ((String, Bool) -> Void)?
    public var onFinalResult: ((TranscriptionResult) -> Void)?
    public var onError: ((Error) -> Void)?
    /// Raised on the main actor at most once per start, when this run's own
    /// input tap accepts a buffer with a positive frame count (issue #983).
    public var onFirstInputBuffer: (() -> Void)?
    /// Local startup-boundary observations for this start (issue #972).
    /// Measurement only: it changes no capture order, ordering guarantee or
    /// audio behaviour.
    public var onStartupObservation: ((StartupObservation) -> Void)?

    // MARK: - Test seams

    // Isolates permission/analyzer boundaries in cancellation tests.
    var permissionCheck: (() async -> Bool)?
    var analyzerStart: (() async throws -> Void)?
    var legacyStart: (() throws -> Void)?
    /// Owns the legacy recogniser; tests inject its recogniser, capability and deadline.
    let legacyRecognition: LegacyAppleRecognitionController

    // MARK: - Private

    private let audioSessionManager: AudioSessionManager
    private let startup = RecordingStartupOperation()
    private let captureInput: LiveCaptureInput
    private let captureTap: AppleSpeechCaptureTap
    private var isStopping = false
    /// Replaced per start so a retired run's tap can never report input for
    /// the run that replaced it.
    private var firstInputSignal = FirstInputSignal()
    private var activeCaptureID: UUID?
    private var legacyStopTask: Task<TranscriptionResult, Never>?
    /// An `AppleSpeechAnalyzerCapture` while the iOS 26 analyzer is running.
    private var analyzerCapture: AnyObject?
    private var analyzerCancellationTask: Task<Void, Never>?
    private var activeModelID = AppleLocalModels.legacySpeechModelID
    private var startTime: Date?

    /// Persistent audio recorder — saves audio to disk alongside transcription.
    public let audioRecorder: AudioRecordingPersistence
    let recordingLoss: RecordingLossReporting

    // MARK: - Init

    public init(audioSessionManager: AudioSessionManager) {
        let input = LiveCaptureInput(audioSessionManager: audioSessionManager)
        let tap = AppleSpeechCaptureTap()
        let recorder = AudioRecordingPersistence()
        let recordingLoss = RecordingLossReporting()
        self.audioSessionManager = audioSessionManager
        captureInput = input
        captureTap = tap
        audioRecorder = recorder
        self.recordingLoss = recordingLoss
        legacyRecognition = LegacyAppleRecognitionController(
            input: input, tap: tap, recorder: recorder, recordingLoss: recordingLoss
        )
        legacyRecognition.host = self
    }

    // MARK: - Public API

    /// Check and request all required permissions.
    public func ensurePermissions() async -> Bool {
        if let permissionCheck { return await permissionCheck() }
        switch await AppleSpeechReadiness.request(using: audioSessionManager) {
        case .granted: return true
        case .cancelled: return false
        case .denied(let permission):
            error = iOSTranscriptionError.permissionDenied(permission)
            return false
        }
    }

    /// Start live transcription session.
    public func start() async throws {
        try await start(preRollBuffers: [], analyzerFallbackAllowed: true)
    }

    public func start(
        preRollBuffers: [AVAudioPCMBuffer],
        analyzerFallbackAllowed: Bool = true
    ) async throws {
        guard !isRunning, !isStopping, !startup.isStarting else { return }
        do {
            try await startup.run({
                await self.awaitCancellationSettled()
                try Task.checkCancellation()
                try await self.startCapture(
                    preRollBuffers: preRollBuffers, analyzerFallbackAllowed: analyzerFallbackAllowed
                )
            }, onFailure: {
                self.cleanupCapture()
                await self.awaitCancellationSettled()
            })
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    /// Stop transcription and return final result.
    public func stop() async -> TranscriptionResult {
        captureInput.disarmDisruptionHandling()
        let lossRun = recordingLoss.currentReport
        if let legacyStopTask { return await legacyStopTask.value }
        guard isRunning, !isStopping else { return buildFinalResult(duration: 0) }

        isStopping = true
        defer { isStopping = false }
        if #available(iOS 26.0, *), let capture = analyzerCapture as? AppleSpeechAnalyzerCapture {
            return await stopSpeechAnalyzer(capture)
        }

        let captureID = activeCaptureID
        let task = Task { await self.stopLegacyCapture(captureID: captureID, lossRun: lossRun) }
        legacyStopTask = task
        let result = await task.value
        legacyStopTask = nil
        return result
    }

    /// Cancel transcription without returning result.
    public func cancel() {
        captureInput.disarmDisruptionHandling()
        startup.cancel()
        cleanupCapture()
    }

    func awaitCancellationSettled() async {
        guard let task = analyzerCancellationTask else { return }
        await task.value
        analyzerCancellationTask = nil
    }

    // MARK: - Start

    private func startCapture(
        preRollBuffers: [AVAudioPCMBuffer],
        analyzerFallbackAllowed: Bool
    ) async throws {
        recordingLoss.begin(recorder: audioRecorder)
        let captureID = beginCapture()
        SpeakLogger.logTranscription(event: "start", model: "Apple Speech")

        // Verify permissions
        let permissionsGranted = await ensurePermissions()
        try Task.checkCancellation()
        guard permissionsGranted else {
            let err = error ?? iOSTranscriptionError.permissionDenied(.microphone)
            SpeakLogger.logError(err, context: "iOSLiveTranscriber.start", logger: SpeakLogger.transcription)
            throw err
        }

        try await configureAudioSession()
        resetState()

        var analyzerAssetsMissing = false
        if AppleLocalModels.isSpeechAnalyzerModel(modelID), #available(iOS 26.0, *) {
            do {
                try await startAnalyzerCapture(preRollBuffers: preRollBuffers, captureID: captureID)
                try Task.checkCancellation()
                isRunning = true
                // Arm here as well as inside the engine start: an injected
                // analyzer session never reaches that path, and this is the
                // point at which the capture is live and interruptible.
                observeCaptureConfiguration()
                logger.info("Started with SpeechAnalyzer (\(self.activeModelID))")
                return
            } catch {
                analyzerAssetsMissing = try AppleSpeechAnalyzerCapture.assetsMissingForFallback(
                    after: error, fallbackAllowed: analyzerFallbackAllowed
                )
            }
        }

        try startLegacyCapture(captureID: captureID, analyzerAssetsMissing: analyzerAssetsMissing)
    }

    /// Starts a fresh capture identity, so a retired run's tap can never
    /// report input for the run that replaced it.
    private func beginCapture() -> UUID {
        let captureID = UUID()
        activeCaptureID = captureID
        firstInputSignal = FirstInputSignal()
        return captureID
    }

    private func configureAudioSession() async throws {
        do {
            try await captureInput.claimAudioSession()
            onStartupObservation?(.stage(.audioSessionConfigured))
            try Task.checkCancellation()
            SpeakLogger.audio.info("Audio session configured for recording")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SpeakLogger.logError(error, context: "Audio session setup", logger: SpeakLogger.audio)
            throw iOSTranscriptionError.audioSessionFailed(error)
        }
    }

    private func resetState() {
        partialText = ""
        isFinal = false
        confidence = nil
        error = nil
        legacyRecognition.reset()
        startTime = Date()
    }

    @available(iOS 26.0, *)
    private func startAnalyzerCapture(preRollBuffers: [AVAudioPCMBuffer], captureID: UUID) async throws {
        let engine = AppleSpeechAnalyzerEngine(modelID: modelID)
        if let analyzerStart {
            try await analyzerStart()
            activeModelID = engine.modelID
            return
        }
        let capture = try await AppleSpeechAnalyzerCapture.start(.init(
            localeIdentifier: language,
            engine: engine,
            preRollBuffers: preRollBuffers,
            input: captureInput,
            tap: captureTap,
            recorder: audioRecorder,
            recordingLoss: recordingLoss,
            onFirstInput: firstInputReporter(captureID: captureID),
            onEngineStarted: { [weak self] in self?.reportEngineStarted(.appleAnalyzer) },
            onUpdate: { [weak self] update in
                Task { @MainActor [weak self] in
                    guard let self, self.activeCaptureID == captureID else { return }
                    self.publishTranscript(update.text, isFinal: update.isFinal, confidence: update.confidence)
                }
            }
        ))
        observeCaptureConfiguration()
        activeModelID = capture.modelIdentifier
        analyzerCapture = capture
    }

    private func startLegacyCapture(captureID: UUID, analyzerAssetsMissing: Bool) throws {
        activeModelID = AppleLocalModels.legacySpeechModelID
        do {
            if let legacyStart {
                try legacyRecognition.requireInjectedCapabilityIfStrict()
                try legacyStart()
            } else {
                try legacyRecognition.startCapture(captureID: captureID, language: language)
            }
        } catch {
            if analyzerAssetsMissing, case iOSTranscriptionError.recognizerUnavailable = error {
                throw AppleSpeechReadiness.modelPreparationError
            }
            throw error
        }

        isRunning = true
        observeCaptureConfiguration()
        logger.info("Started")
    }

    /// Runs on the render thread; the signal keeps it to one main-actor hop.
    func firstInputReporter(captureID: UUID?) -> () -> Void {
        let signal = firstInputSignal
        return { [weak self] in
            guard let captureID, signal.markObserved() else { return }
            Task { @MainActor [weak self] in self?.reportFirstInputBuffer(captureID) }
        }
    }

    private func reportFirstInputBuffer(_ captureID: UUID) {
        guard activeCaptureID == captureID else { return }
        onFirstInputBuffer?()
    }

    private func observeCaptureConfiguration() {
        captureInput.armDisruptionHandling { [weak self] in
            guard let self else { return false }
            return self.isRunning && !self.isStopping
        } onStopped: { [weak self] reason in
            self?.reportCaptureDisruption(reason)
        }
    }

    private func reportCaptureDisruption(_ reason: iOSTranscriptionError) {
        // The owner drains the provider and recording once through its normal stop path.
        // Interruption itself is a stopped notice; a real drain failure still reaches onError.
        if !reason.isControlledInterruption { error = reason }
        onError?(reason)
    }
}

// MARK: - Stop and cancel

private extension iOSLiveTranscriber {
    func stopLegacyCapture(captureID: UUID?, lossRun: RecordingLossReport) async -> TranscriptionResult {
        guard let duration = await legacyRecognition.stop(captureID: captureID, lossRun: lossRun, since: startTime)
        else { return cancelledStopResult() }
        let result = buildFinalResult(duration: duration)
        legacyRecognition.release()
        return completeStop(result, loggedModel: "Apple Speech")
    }

    @available(iOS 26.0, *)
    func stopSpeechAnalyzer(_ capture: AppleSpeechAnalyzerCapture) async -> TranscriptionResult {
        let result: TranscriptionResult
        switch await capture.finish(since: startTime) {
        case .success(let analyzerResult):
            result = analyzerResult
        case .failure(let failure):
            error = failure.error
            onError?(failure.error)
            result = makeResult(text: partialText, segments: [], confidence: confidence, duration: failure.elapsed)
        }
        analyzerCapture = nil
        return completeStop(result, loggedModel: activeModelID)
    }

    func completeStop(_ result: TranscriptionResult, loggedModel: String) -> TranscriptionResult {
        isRunning = false
        activeCaptureID = nil
        captureInput.releaseAudioSession()
        SpeakLogger.logTranscription(
            event: "stop", model: loggedModel, wordCount: result.text.split(separator: " ").count
        )
        onFinalResult?(result)
        return result
    }

    func cancelledStopResult() -> TranscriptionResult {
        makeResult(text: "", segments: [], confidence: nil, duration: 0)
    }

    func buildFinalResult(duration: TimeInterval) -> TranscriptionResult {
        // partialText already includes the text committed by earlier tasks.
        let (segments, finalConfidence) = legacyRecognition.assembly.finalSegments(fallbackConfidence: confidence)
        return makeResult(text: partialText, segments: segments, confidence: finalConfidence, duration: duration)
    }

    func makeResult(
        text: String, segments: [TranscriptionSegment], confidence: Double?, duration: TimeInterval
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: text, segments: segments, confidence: confidence, duration: duration,
            modelIdentifier: activeModelID, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }

    // MARK: - Cancel

    func cleanupCapture() {
        captureInput.disarmDisruptionHandling()
        recordingLoss.cancel()
        activeCaptureID = nil
        legacyRecognition.retire()
        guard isRunning || captureInput.holdsCaptureResources else { return }

        SpeakLogger.transcription.info("Cancelling transcription")

        // Stop input first, then drain the queue so tap work already enqueued
        // cannot write to the recorder or feed the analyser after they have been
        // torn down below. Synchronous (not `await`) keeps cancellation atomic on
        // the main actor; the queued work never waits on the main actor, so it
        // cannot deadlock.
        captureInput.halt()
        captureTap.drainSynchronously()
        legacyRecognition.tearDown()

        // Explicit cancellation discards the partial recording.
        audioRecorder.cancelRecording()

        if #available(iOS 26.0, *), let capture = analyzerCapture as? AppleSpeechAnalyzerCapture {
            analyzerCancellationTask = capture.cancel()
        }
        analyzerCapture = nil
        isRunning = false
        activeCaptureID = nil

        captureInput.releaseAudioSession()

        logger.info("Cancelled")
    }
}

// MARK: - Legacy recognition host

extension iOSLiveTranscriber: LegacyAppleRecognitionHost {
    func isCurrentCapture(_ captureID: UUID) -> Bool { activeCaptureID == captureID }
    var isCaptureRunning: Bool { isRunning }
    var isCaptureStopping: Bool { isStopping }

    func publishTranscript(_ text: String, isFinal: Bool, confidence: Double?) {
        partialText = text
        self.isFinal = isFinal
        self.confidence = confidence
        onPartialResult?(text, isFinal)
    }

    func legacyRecognitionDidFail(_ error: Error) {
        self.error = error
        onError?(error)
    }

    /// `backend` is the branch that actually ran, and its engine has
    /// actually returned (issue #972).
    func reportEngineStarted(_ backend: StartupBackend) {
        onStartupObservation?(.backend(backend))
        onStartupObservation?(.stage(.engineStarted))
    }

    func legacyTapWasRejected() {
        guard isRunning, !isStopping else { return }
        captureInput.disarmDisruptionHandling()
        captureInput.halt()
        reportCaptureDisruption(.microphoneChanged)
    }
}
#endif
// swiftlint:enable file_length
