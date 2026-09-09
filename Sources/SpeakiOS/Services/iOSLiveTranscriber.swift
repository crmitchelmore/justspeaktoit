#if os(iOS)
import AVFoundation
import Foundation
import Speech
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "iOSLiveTranscriber")

// swiftlint:disable file_length
/// iOS-native live transcription using Apple Speech framework.
@MainActor
// swiftlint:disable:next type_body_length
public final class iOSLiveTranscriber: ObservableObject {
    // MARK: - Published State

    @Published private(set) public var isRunning = false
    @Published private(set) public var partialText = ""
    @Published private(set) public var isFinal = false
    @Published private(set) public var confidence: Double?
    @Published private(set) public var error: Error?

    // MARK: - Configuration

    public var language: String = Locale.current.identifier
    public var preferOnDevice: Bool = true
    public var modelID: String = AppleLocalModels.preferredSpeechModelID

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

    // MARK: - Private

    private let audioSessionManager: AudioSessionManager
    private let startup = RecordingStartupOperation()
    private var ownsAudioSession = false
    private var hasInputTap = false
    /// Replaced per start so a retired run's tap can never report input for
    /// the run that replaced it.
    private var firstInputSignal = FirstInputSignal()

    /// Starts a fresh capture identity, so a retired run's tap can never
    /// report input for the run that replaced it.
    private func beginCapture() -> UUID {
        let captureID = UUID()
        activeCaptureID = captureID
        firstInputSignal = FirstInputSignal()
        return captureID
    }

    /// The analyzer branch is the one that actually ran, and the engine has
    /// actually returned (issue #972).
    private func reportAnalyzerEngineStarted() {
        onStartupObservation?(.backend(.appleAnalyzer))
        onStartupObservation?(.stage(.engineStarted))
    }

    /// Hopped to from the audio thread once, never per buffer.
    private func reportFirstInputBuffer(_ captureID: UUID) {
        guard activeCaptureID == captureID else { return }
        onFirstInputBuffer?()
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        audioSessionManager.deactivate()
        ownsAudioSession = false
    }

    private func removeInputTap() {
        guard hasInputTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInputTap = false
    }
    private var speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private let configurationObserver = CaptureDisruptionObserver()
    private let captureInterruptionObserver = CaptureDisruptionObserver()
    private var isStopping = false
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: LegacyAppleRecognitionTask?
    private var latestResult: LegacyAppleRecognitionUpdate?
    private var activeRecognitionID: UUID?
    private var legacyStopTask: Task<TranscriptionResult, Never>?
    private var legacyFinalisationContinuation: CheckedContinuation<Void, Never>?
    private var cancelLegacyDeadline: (() -> Void)?
    var legacyRecognitionStart: ((@escaping (LegacyAppleRecognitionUpdate?, Error?) -> Void)
        -> LegacyAppleRecognitionTask)?
    /// Cap the recognizer wait at two seconds after queued audio drains, keeping
    /// an unresponsive framework from holding Stop indefinitely. Return early on
    /// a terminal callback; this ceiling still needs device latency validation.
    /// Device latency/trailing-word coverage is tracked in issue #948.
    var scheduleLegacyDeadline: (@escaping () -> Void) -> (() -> Void) = { completion in
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            completion()
        }
        return { task.cancel() }
    }
    private var speechAnalyzerSession: Any?
    private var analyzerCancellationTask: Task<Void, Never>?
    private var activeCaptureID: UUID?
    private var speechAnalyzerConverter: Any?
    // Isolates permission/analyzer boundaries in cancellation tests.
    var permissionCheck: (() async -> Bool)?
    var analyzerStart: (() async throws -> Void)?
    var legacyStart: (() throws -> Void)?
    private var activeModelID = AppleLocalModels.legacySpeechModelID
    private var startTime: Date?
    private var accumulatedSegments: [TranscriptionSegment] = []
    private var isShuttingDownRecognitionTask = false
    /// Accumulated text from recognition segments finalised mid-session (on pause).
    private var committedText: String = ""
    /// Last `formattedString` received from the recognizer, used to detect
    /// implicit text resets where Apple silently clears the transcript.
    private var lastFormattedString: String = ""

    private static let assistantErrorDomain = "kAFAssistantErrorDomain"
    private static let cancelledTaskErrorCode = 209

    /// Persistent audio recorder — saves audio to disk alongside transcription.
    public let audioRecorder = AudioRecordingPersistence()

    /// Serial queue that takes tap buffers off the real-time audio thread —
    /// recognition feeding and persistence run here, not in the tap callback.
    private let audioProcessingQueue = DispatchQueue(label: "com.speak.ios.applespeech.audioProcessing")
    /// Pool for tap-buffer copies so the hot path never allocates.
    private let tapBufferPool = PCMBufferPool(maximumBuffers: 4)

    // MARK: - Init

    public init(audioSessionManager: AudioSessionManager) {
        self.audioSessionManager = audioSessionManager
    }

    // MARK: - Public API

    /// Check and request all required permissions.
    public func ensurePermissions() async -> Bool {
        if let permissionCheck { return await permissionCheck() }
        // Check microphone
        if !audioSessionManager.hasMicrophonePermission() {
            let granted = await audioSessionManager.requestMicrophonePermission()
            guard !Task.isCancelled else { return false }
            if !granted {
                error = iOSTranscriptionError.permissionDenied(.microphone)
                return false
            }
        }

        // Check speech recognition
        guard !Task.isCancelled else { return false }
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus != .authorized {
            let granted = await CancellablePermissionRequest.request { completion in
                SFSpeechRecognizer.requestAuthorization { status in
                    completion(status == .authorized)
                }
            }
            guard !Task.isCancelled else { return false }
            if !granted {
                error = iOSTranscriptionError.permissionDenied(.speechRecognition)
                return false
            }
        }

        return true
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
                await self.finishAnalyzerCancellation()
                try Task.checkCancellation()
                try await self.startCapture(
                    preRollBuffers: preRollBuffers, analyzerFallbackAllowed: analyzerFallbackAllowed
                )
            }, onFailure: {
                self.cleanupCapture()
                await self.finishAnalyzerCancellation()
            })
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    // swiftlint:disable:next function_body_length
    private func startCapture(
        preRollBuffers: [AVAudioPCMBuffer],
        analyzerFallbackAllowed: Bool
    ) async throws {
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
        if AppleLocalModels.isSpeechAnalyzerModel(modelID) {
            if #available(iOS 26.0, *) {
                do {
                    let engine = AppleSpeechAnalyzerEngine(modelID: modelID)
                    if let analyzerStart {
                        try await analyzerStart()
                        activeModelID = engine.modelID
                    } else {
                        try await startSpeechAnalyzer(
                            engine: engine, preRollBuffers: preRollBuffers, captureID: captureID
                        )
                    }
                    try Task.checkCancellation()
                    isRunning = true
                    logger.info("Started with SpeechAnalyzer (\(self.activeModelID))")
                    return
                } catch {
                    // Cancellation is a control action, never a reason to
                    // activate the legacy recognizer after the user stopped.
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    SpeakLogger.logError(
                        error,
                        context: "SpeechAnalyzer setup; falling back to SFSpeechRecognizer",
                        logger: SpeakLogger.transcription
                    )
                    if case AppleLocalModelError.modelAssetsUnavailable = error {
                        analyzerAssetsMissing = true
                    }
                    if !analyzerFallbackAllowed {
                        throw analyzerAssetsMissing ? Self.modelPreparationError : error
                    }
                }
            }
        }

        activeModelID = AppleLocalModels.legacySpeechModelID
        try startLegacyFallback(captureID: captureID, analyzerAssetsMissing: analyzerAssetsMissing)

        isRunning = true
        observeCaptureConfiguration()
        logger.info("Started")
    }

    private func startLegacyFallback(captureID: UUID, analyzerAssetsMissing: Bool) throws {
        do {
            if let legacyStart {
                try legacyStart()
            } else {
                try startLegacyRecognition(captureID: captureID)
            }
        } catch {
            if analyzerAssetsMissing, case iOSTranscriptionError.recognizerUnavailable = error {
                throw Self.modelPreparationError
            }
            throw error
        }
    }

    private static var modelPreparationError: NSError {
        NSError(domain: "AppleSpeechPreparation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Apple's on-device speech model is not ready. "
                + "Open Settings and tap Prepare Apple model, then try again."
        ])
    }

    private func startLegacyRecognition(captureID: UUID) throws {
        if legacyRecognitionStart != nil {
            beginRecognitionTask(captureID: captureID)
        } else {
            let (recognizer, request) = try setupRecognition()
            try startAudioEngine(request: request)
            beginRecognitionTask(captureID: captureID, recognizer: recognizer, request: request)
        }
    }

    private func configureAudioSession() async throws {
        do {
            ownsAudioSession = true
            try await audioSessionManager.configureForRecording()
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

    @available(iOS 26.0, *)
    // One do/catch owns the analyzer session, its tap and its teardown; the
    // engine-start boundary must be reported from inside it (issue #972).
    // swiftlint:disable:next function_body_length
    private func startSpeechAnalyzer(
        engine: AppleSpeechAnalyzerEngine,
        preRollBuffers: [AVAudioPCMBuffer],
        captureID: UUID
    ) async throws {
        let session = try await AppleSpeechAnalyzerLiveSession(
            localeIdentifier: language,
            engine: engine,
            assetPolicy: .installedOnly
        ) { [weak self] update in
            Task { @MainActor [weak self] in
                guard self?.activeCaptureID == captureID else { return }
                self?.handleSpeechAnalyzerUpdate(update)
            }
        }
        do {
            try Task.checkCancellation()
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            let converter = try AppleSpeechAudioConverter(
                sourceFormat: recordingFormat,
                targetFormat: session.audioFormat
            )
            let signal = firstInputSignal
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                // Copy the buffer and hop off the real-time audio thread —
                // heavy work in the tap makes CoreAudio drop mic buffers.
                guard let self, let copied = self.tapBufferPool.copy(buffer) else { return }
                if copied.frameLength > 0, signal.markObserved() {
                    Task { @MainActor [weak self] in self?.reportFirstInputBuffer(captureID) }
                }
                self.audioProcessingQueue.async {
                    defer { self.tapBufferPool.recycle(copied) }
                    self.audioRecorder.writeBuffer(copied)
                    guard let converted = converter.convert(copied) else { return }
                    session.send(converted)
                }
            }
            hasInputTap = true
            _ = try? audioRecorder.startRecording(format: recordingFormat)
            for buffer in preRollBuffers {
                if let converted = converter.convert(buffer) {
                    session.send(converted)
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
            reportAnalyzerEngineStarted()
            observeCaptureConfiguration()
            activeModelID = session.modelIdentifier
            speechAnalyzerSession = session
            speechAnalyzerConverter = converter
        } catch {
            audioEngine.stop()
            removeInputTap()
            audioProcessingQueue.sync {}
            audioRecorder.cancelRecording()
            await session.cancel()
            throw error
        }
    }

    @available(iOS 26.0, *)
    private func handleSpeechAnalyzerUpdate(_ update: AppleSpeechAnalyzerUpdate) {
        partialText = update.text
        isFinal = update.isFinal
        confidence = update.confidence
        onPartialResult?(update.text, update.isFinal)
    }

    private func setupRecognition() throws -> (SFSpeechRecognizer, SFSpeechAudioBufferRecognitionRequest) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable else {
            SpeakLogger.transcription.error("Speech recognizer unavailable for language: \(self.language, privacy: .public)")
            throw iOSTranscriptionError.recognizerUnavailable
        }
        speechRecognizer = recognizer

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            throw iOSTranscriptionError.recognizerUnavailable
        }
        request.shouldReportPartialResults = true
        if preferOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            SpeakLogger.transcription.info("Using on-device recognition")
        } else {
            SpeakLogger.transcription.info("Using server-based recognition")
        }
        return (recognizer, request)
    }

    private func startAudioEngine(request: SFSpeechAudioBufferRecognitionRequest) throws {
        let recordingFormat = installTap(appendingTo: request)
        // The safety writer opens before the engine, so the file covers the
        // very first buffers instead of starting a beat late (issue #992).
        _ = try? audioRecorder.startRecording(format: recordingFormat)
        audioEngine.prepare()
        try audioEngine.start()
        // The legacy branch is the one that actually ran, and the engine has
        // actually returned.
        onStartupObservation?(.backend(.appleLegacy))
        onStartupObservation?(.stage(.engineStarted))
    }

    /// Installs the input tap appending to `request`. The request is captured
    /// as an immutable local so the audio-thread tap never reads the
    /// main-actor `recognitionRequest` property, which is reassigned on
    /// stop/cancel/restart.
    @discardableResult
    private func installTap(appendingTo request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioFormat {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let recorder = audioRecorder
        let pool = tapBufferPool
        let queue = audioProcessingQueue
        let signal = firstInputSignal
        let captureID = activeCaptureID
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            // Copy the buffer and hop off the real-time audio thread —
            // heavy work in the tap makes CoreAudio drop mic buffers.
            // `request` is captured immutably; the tap is reinstalled with the
            // fresh request in `restartRecognitionTask()`.
            guard let copied = pool.copy(buffer) else { return }
            if copied.frameLength > 0, let captureID, signal.markObserved() {
                Task { @MainActor [weak self] in self?.reportFirstInputBuffer(captureID) }
            }
            queue.async {
                defer { pool.recycle(copied) }
                request.append(copied)
                recorder.writeBuffer(copied)
            }
        }
        hasInputTap = true
        return recordingFormat
    }

    private func resetState() {
        partialText = ""
        isFinal = false
        confidence = nil
        error = nil
        latestResult = nil
        accumulatedSegments = []
        isShuttingDownRecognitionTask = false
        committedText = ""
        lastFormattedString = ""
        startTime = Date()
    }

    /// Stop transcription and return final result.
    private func observeCaptureConfiguration() {
        configurationObserver.observe(.AVAudioEngineConfigurationChange, object: audioEngine) { [weak self] in
            self?.audioEngine.isRunning == true
        } onDisruption: { [weak self] in
            self?.handleCaptureDisruption(.microphoneChanged)
        }
        captureInterruptionObserver.observeAudioInterruption { [weak self] in
            self?.handleCaptureDisruption(.interrupted)
        }
    }

    private func handleCaptureDisruption(_ reason: iOSTranscriptionError) {
        guard isRunning, !isStopping else { return }
        configurationObserver.stop()
        captureInterruptionObserver.stop()
        audioEngine.stop()
        removeInputTap()
        // The owner drains the provider and recording once through its normal stop path.
        // Interruption itself is a stopped notice; a real drain failure still reaches onError.
        if !reason.isControlledInterruption { error = reason }
        onError?(reason)
    }

    public func stop() async -> TranscriptionResult {
        configurationObserver.stop()
        captureInterruptionObserver.stop()
        if let legacyStopTask { return await legacyStopTask.value }
        guard isRunning, !isStopping else { return buildFinalResult(duration: 0) }

        isStopping = true
        defer { isStopping = false }
        if #available(iOS 26.0, *),
           let session = speechAnalyzerSession as? AppleSpeechAnalyzerLiveSession {
            return await stopSpeechAnalyzer(session)
        }

        let captureID = activeCaptureID
        let task = Task { await self.stopLegacyRecognition(captureID: captureID) }
        legacyStopTask = task
        let result = await task.value
        legacyStopTask = nil
        return result
    }

    private func stopLegacyRecognition(captureID: UUID?) async -> TranscriptionResult {
        isShuttingDownRecognitionTask = true

        // Stop audio engine first, then let the buffers already queued on the
        // processing queue be appended to the request — `endAudio()` before the
        // drain would discard the last words spoken.
        audioEngine.stop()
        removeInputTap()
        await audioProcessingQueue.drainPendingWork()

        guard activeCaptureID == captureID, captureID != nil else { return cancelledStopResult() }
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        recognitionTask?.endAudio()
        await awaitLegacyFinalisation()
        // Cancel may have discarded this capture while the actor was suspended.
        guard activeCaptureID == captureID else { return cancelledStopResult() }
        activeRecognitionID = nil
        recognitionTask?.cancel()

        // Stop persistent recording
        _ = audioRecorder.stopRecording()

        // Build final result
        let result = buildFinalResult(duration: duration)

        // Cleanup
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        isRunning = false
        activeCaptureID = nil

        releaseAudioSession()

        SpeakLogger.logTranscription(event: "stop", model: "Apple Speech", wordCount: result.text.split(separator: " ").count)
        onFinalResult?(result)

        return result
    }

    private func awaitLegacyFinalisation() async {
        // A terminal callback may already have arrived during the buffer drain.
        guard let recognitionID = activeRecognitionID, let recognitionTask else { return }
        let captureID = activeCaptureID
        let beganWaiting = Date()
        await withCheckedContinuation { continuation in
            legacyFinalisationContinuation = continuation
            cancelLegacyDeadline = scheduleLegacyDeadline { [weak self] in
                guard let self, self.activeCaptureID == captureID,
                      self.activeRecognitionID == recognitionID else { return }
                logger.warning("Legacy Apple finalisation deadline reached; retaining the latest usable result")
                self.completeLegacyFinalisation()
            }
            recognitionTask.finish()
        }
        let elapsed = Date().timeIntervalSince(beganWaiting)
        logger.info("Legacy Apple finalisation wait: \(elapsed, privacy: .public)s")
    }

    private func completeLegacyFinalisation() {
        cancelLegacyDeadline?()
        cancelLegacyDeadline = nil
        let continuation = legacyFinalisationContinuation
        legacyFinalisationContinuation = nil
        continuation?.resume()
    }

    private func cancelledStopResult() -> TranscriptionResult {
        TranscriptionResult(text: "", segments: [], confidence: nil, duration: 0,
                            modelIdentifier: activeModelID, cost: nil, rawPayload: nil, debugInfo: nil)
    }

    @available(iOS 26.0, *)
    private func stopSpeechAnalyzer(_ session: AppleSpeechAnalyzerLiveSession) async -> TranscriptionResult {
        audioEngine.stop()
        removeInputTap()
        // Let queued buffers reach the analyser and the recorder before
        // `session.finish()` and the recorder close below.
        await audioProcessingQueue.drainPendingWork()
        _ = audioRecorder.stopRecording()

        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let result: TranscriptionResult
        do {
            let analyzerResult = try await session.finish()
            result = TranscriptionResult(
                text: analyzerResult.text,
                segments: analyzerResult.segments,
                confidence: analyzerResult.confidence,
                duration: max(elapsed, analyzerResult.duration),
                modelIdentifier: activeModelID,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        } catch {
            self.error = error
            onError?(error)
            result = TranscriptionResult(
                text: partialText,
                segments: [],
                confidence: confidence,
                duration: elapsed,
                modelIdentifier: activeModelID,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }

        speechAnalyzerSession = nil
        speechAnalyzerConverter = nil
        isRunning = false
        activeCaptureID = nil
        releaseAudioSession()
        SpeakLogger.logTranscription(
            event: "stop",
            model: activeModelID,
            wordCount: result.text.split(separator: " ").count
        )
        onFinalResult?(result)
        return result
    }

    /// Cancel transcription without returning result.
    public func cancel() {
        configurationObserver.stop()
        captureInterruptionObserver.stop()
        startup.cancel()
        cleanupCapture()
    }

    private func cleanupCapture() {
        configurationObserver.stop()
        captureInterruptionObserver.stop()
        activeCaptureID = nil
        activeRecognitionID = nil
        completeLegacyFinalisation()
        guard isRunning || ownsAudioSession || hasInputTap else { return }

        SpeakLogger.transcription.info("Cancelling transcription")

        isShuttingDownRecognitionTask = true

        // Stop input first, then drain the queue so tap work already enqueued
        // cannot write to the recorder or feed the analyser after they have been
        // torn down below. `sync` (not `await`) keeps cancellation atomic on the
        // main actor; the queued work never waits on the main actor, so it
        // cannot deadlock.
        audioEngine.stop()
        removeInputTap()
        audioProcessingQueue.sync {}

        recognitionTask?.endAudio()
        recognitionTask?.cancel()

        // Explicit cancellation discards the partial recording.
        audioRecorder.cancelRecording()

        if #available(iOS 26.0, *),
           let session = speechAnalyzerSession as? AppleSpeechAnalyzerLiveSession {
            analyzerCancellationTask = Task { await session.cancel() }
        }

        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        speechAnalyzerSession = nil
        speechAnalyzerConverter = nil
        isRunning = false
        activeCaptureID = nil

        releaseAudioSession()

        logger.info("Cancelled")
    }

    private func finishAnalyzerCancellation() async {
        guard let task = analyzerCancellationTask else { return }
        await task.value
        analyzerCancellationTask = nil
    }

    // MARK: - Private

    private func beginRecognitionTask(
        captureID: UUID,
        recognizer: SFSpeechRecognizer? = nil,
        request: SFSpeechAudioBufferRecognitionRequest? = nil
    ) {
        let recognitionID = UUID()
        activeRecognitionID = recognitionID
        isShuttingDownRecognitionTask = false
        let receive: (LegacyAppleRecognitionUpdate?, Error?) -> Void = { [weak self] result, error in
            guard let self, self.activeCaptureID == captureID,
                  self.activeRecognitionID == recognitionID else { return }
            self.handleRecognitionResult(result, error: error)
        }
        if let legacyRecognitionStart {
            recognitionTask = legacyRecognitionStart(receive)
        } else if let recognizer, let request {
            let task = recognizer.recognitionTask(with: request) { result, error in
                let update = result.map(LegacyAppleRecognitionUpdate.init)
                Task { @MainActor in receive(update, error) }
            }
            recognitionTask = LegacyAppleRecognitionTask(
                endAudio: request.endAudio, finish: task.finish, cancel: task.cancel
            )
        }
    }

    private func handleRecognitionResult(_ result: LegacyAppleRecognitionUpdate?, error: Error?) {
        let captureID = activeCaptureID
        let terminal = result?.isFinal == true || error != nil
        if terminal { activeRecognitionID = nil }
        // Empty terminal payloads must not erase a usable preceding partial.
        if let result, !terminal || !result.text.isEmpty || lastFormattedString.isEmpty {
            commitIfImplicitReset(currentText: result.text, isFinal: result.isFinal)
            latestResult = result
            lastFormattedString = result.text
            partialText = [committedText, result.text].filter { !$0.isEmpty }.joined(separator: " ")
            isFinal = result.isFinal
            confidence = result.confidence
            if result.isFinal {
                committedText = partialText
                lastFormattedString = ""
            }
            onPartialResult?(partialText, result.isFinal)
        }
        // Callbacks can synchronously Cancel; never resume/restart that capture.
        guard activeCaptureID == captureID else { return }
        if terminal { completeLegacyFinalisation() }
        if let error {
            let nsError = error as NSError
            if nsError.domain == Self.assistantErrorDomain,
               nsError.code == Self.cancelledTaskErrorCode,
               isShuttingDownRecognitionTask || !isRunning { return }
            logger.error("Recognition error: \(error.localizedDescription, privacy: .public)")
            self.error = iOSTranscriptionError.recognitionFailed(error)
            onError?(self.error!)
        } else if result?.isFinal == true, !isStopping {
            restartRecognitionTask()
        }
    }

    /// Detect when Apple's recognizer silently resets `formattedString` after
    /// a pause without sending `isFinal`.  If the new text is dramatically
    /// shorter than the previous result, commit the old text to prevent loss.
    private func commitIfImplicitReset(currentText: String, isFinal: Bool) {
        guard !isFinal,
              lastFormattedString.count >= 1,
              currentText.count < lastFormattedString.count / 2
        else { return }
        logger.info("Implicit text reset – committing \(self.lastFormattedString.count) chars")
        committedText = [committedText, lastFormattedString]
            .filter { !$0.isEmpty }.joined(separator: " ")
        appendLatestSegments()
    }

    /// Restart recognition after a mid-session `isFinal` so continued speech
    /// is captured without losing previously committed text.
    private func restartRecognitionTask() {
        guard isRunning, !isStopping, let captureID = activeCaptureID,
              speechRecognizer != nil || legacyRecognitionStart != nil else { return }

        isShuttingDownRecognitionTask = true
        appendLatestSegments()

        // Let buffers already queued reach the *old* request before its task is
        // cancelled — the tap captured that request immutably, so anything still
        // queued would otherwise be appended to a dead request and dropped.
        // `sync` (not `await`) because the restart must stay atomic on the main
        // actor; the queued work is an append plus a buffer copy, and nothing on
        // this queue ever waits on the main actor, so it cannot deadlock.
        audioProcessingQueue.sync {}

        recognitionTask?.cancel()
        recognitionTask = nil
        latestResult = nil
        lastFormattedString = ""
        if legacyRecognitionStart != nil {
            beginRecognitionTask(captureID: captureID)
            return
        }
        guard let recognizer = speechRecognizer else { return }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if preferOnDevice && recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        recognitionRequest = newRequest

        // Reinstall the tap so its closure captures the new request; the old
        // tap holds the previous (cancelled) request immutably.
        removeInputTap()
        installTap(appendingTo: newRequest)

        beginRecognitionTask(captureID: captureID, recognizer: recognizer, request: newRequest)
    }
    private func appendLatestSegments() {
        guard let latestResult else { return }
        accumulatedSegments.append(contentsOf: latestResult.segments)
    }

    private func buildFinalResult(duration: TimeInterval) -> TranscriptionResult {
        let latestSegments = latestResult?.segments ?? []
        let finalSegments = accumulatedSegments + latestSegments
        let confidences = finalSegments.compactMap(\.confidence)
        let finalConfidence = confidences.isEmpty ? confidence : confidences.reduce(0, +) / Double(confidences.count)

        // partialText already includes committedText from previous segments
        return TranscriptionResult(
            text: partialText,
            segments: finalSegments,
            confidence: finalConfidence,
            duration: duration,
            modelIdentifier: activeModelID,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }
}
#endif
// swiftlint:enable file_length
