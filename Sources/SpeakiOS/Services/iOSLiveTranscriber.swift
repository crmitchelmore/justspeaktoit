#if os(iOS)
import AVFoundation
import Foundation
import Speech
import SpeakCore
import os.log

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

    // MARK: - Private

    private let audioSessionManager: AudioSessionManager
    private var speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestResult: SFSpeechRecognitionResult?
    private var speechAnalyzerSession: Any?
    private var speechAnalyzerConverter: Any?
    private var activeModelID = AppleLocalModels.legacySpeechModelID
    private var startTime: Date?
    private var accumulatedSegments: [TranscriptionSegment] = []
    private var segments: [TranscriptionSegment] = []
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
        setupInterruptionHandling()
    }

    // MARK: - Public API

    /// Check and request all required permissions.
    public func ensurePermissions() async -> Bool {
        // Check microphone
        if !audioSessionManager.hasMicrophonePermission() {
            let granted = await audioSessionManager.requestMicrophonePermission()
            if !granted {
                error = iOSTranscriptionError.permissionDenied(.microphone)
                return false
            }
        }

        // Check speech recognition
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus != .authorized {
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
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
        guard !isRunning else { return }

        SpeakLogger.logTranscription(event: "start", model: "Apple Speech")

        // Verify permissions
        guard await ensurePermissions() else {
            let err = error ?? iOSTranscriptionError.permissionDenied(.microphone)
            SpeakLogger.logError(err, context: "iOSLiveTranscriber.start", logger: SpeakLogger.transcription)
            throw err
        }

        // Configure audio session
        do {
            try await audioSessionManager.configureForRecording()
            SpeakLogger.audio.info("Audio session configured for recording")
        } catch {
            SpeakLogger.logError(error, context: "Audio session setup", logger: SpeakLogger.audio)
            throw iOSTranscriptionError.audioSessionFailed(error)
        }

        resetState()

        if AppleLocalModels.isSpeechAnalyzerModel(modelID) {
            if #available(iOS 26.0, *) {
                do {
                    let engine = AppleSpeechAnalyzerEngine(modelID: modelID)
                    try await startSpeechAnalyzer(engine: engine, preRollBuffers: preRollBuffers)
                    activeModelID = engine.modelID
                    isRunning = true
                    print("[iOSLiveTranscriber] Started with SpeechAnalyzer (\(engine.modelID))")
                    return
                } catch {
                    SpeakLogger.logError(
                        error,
                        context: "SpeechAnalyzer setup; falling back to SFSpeechRecognizer",
                        logger: SpeakLogger.transcription
                    )
                    if !analyzerFallbackAllowed { throw error }
                }
            }
        }

        activeModelID = AppleLocalModels.legacySpeechModelID
        let (recognizer, request) = try setupRecognition()
        try startAudioEngine(request: request)

        // Start recognition
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result, error: error)
            }
        }

        isRunning = true
        print("[iOSLiveTranscriber] Started")
    }

    @available(iOS 26.0, *)
    private func startSpeechAnalyzer(
        engine: AppleSpeechAnalyzerEngine,
        preRollBuffers: [AVAudioPCMBuffer]
    ) async throws {
        let session = try await AppleSpeechAnalyzerLiveSession(
            localeIdentifier: language,
            engine: engine
        ) { [weak self] update in
            Task { @MainActor [weak self] in
                self?.handleSpeechAnalyzerUpdate(update)
            }
        }
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        do {
            let converter = try AppleSpeechAudioConverter(
                sourceFormat: recordingFormat,
                targetFormat: session.audioFormat
            )
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                // Copy the buffer and hop off the real-time audio thread —
                // heavy work in the tap makes CoreAudio drop mic buffers.
                guard let self, let copied = self.tapBufferPool.copy(buffer) else { return }
                self.audioProcessingQueue.async {
                    defer { self.tapBufferPool.recycle(copied) }
                    self.audioRecorder.writeBuffer(copied)
                    guard let converted = converter.convert(copied) else { return }
                    session.send(converted)
                }
            }
            _ = try? audioRecorder.startRecording(format: recordingFormat)
            for buffer in preRollBuffers {
                audioRecorder.writeBuffer(buffer)
                if let converted = converter.convert(buffer) {
                    session.send(converted)
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
            speechAnalyzerSession = session
            speechAnalyzerConverter = converter
        } catch {
            audioEngine.stop()
            inputNode.removeTap(onBus: 0)
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
        audioEngine.prepare()
        try audioEngine.start()
        _ = try? audioRecorder.startRecording(format: recordingFormat)
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            // Copy the buffer and hop off the real-time audio thread —
            // heavy work in the tap makes CoreAudio drop mic buffers.
            // `request` is captured immutably; the tap is reinstalled with the
            // fresh request in `restartRecognitionTask()`.
            guard let copied = pool.copy(buffer) else { return }
            queue.async {
                defer { pool.recycle(copied) }
                request.append(copied)
                recorder.writeBuffer(copied)
            }
        }
        return recordingFormat
    }

    private func resetState() {
        partialText = ""
        isFinal = false
        confidence = nil
        error = nil
        latestResult = nil
        accumulatedSegments = []
        segments = []
        isShuttingDownRecognitionTask = false
        committedText = ""
        lastFormattedString = ""
        startTime = Date()
    }

    /// Stop transcription and return final result.
    public func stop() async -> TranscriptionResult {
        guard isRunning else {
            return TranscriptionResult(
                text: partialText,
                segments: segments,
                confidence: confidence,
                duration: 0,
                modelIdentifier: activeModelID,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }

        if #available(iOS 26.0, *),
           let session = speechAnalyzerSession as? AppleSpeechAnalyzerLiveSession {
            return await stopSpeechAnalyzer(session)
        }

        isShuttingDownRecognitionTask = true

        // Stop audio engine first, then let the buffers already queued on the
        // processing queue be appended to the request — `endAudio()` before the
        // drain would discard the last words spoken.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        await audioProcessingQueue.drainPendingWork()

        // Signal end of audio
        recognitionRequest?.endAudio()

        // Cancel recognition task
        recognitionTask?.cancel()

        // Stop persistent recording
        _ = audioRecorder.stopRecording()

        // Build final result
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let result = buildFinalResult(duration: duration)

        // Cleanup
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        isRunning = false

        audioSessionManager.deactivate()

        SpeakLogger.logTranscription(event: "stop", model: "Apple Speech", wordCount: result.text.split(separator: " ").count)
        onFinalResult?(result)

        return result
    }

    @available(iOS 26.0, *)
    private func stopSpeechAnalyzer(_ session: AppleSpeechAnalyzerLiveSession) async -> TranscriptionResult {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
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
        audioSessionManager.deactivate()
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
        guard isRunning else { return }

        SpeakLogger.transcription.info("Cancelling transcription")

        isShuttingDownRecognitionTask = true

        // Stop input first, then drain the queue so tap work already enqueued
        // cannot write to the recorder or feed the analyser after they have been
        // torn down below. `sync` (not `await`) keeps cancellation atomic on the
        // main actor; the queued work never waits on the main actor, so it
        // cannot deadlock.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioProcessingQueue.sync {}

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        // Cancel persistent recording (keeps partial file by default)
        audioRecorder.cancelRecording()

        if #available(iOS 26.0, *),
           let session = speechAnalyzerSession as? AppleSpeechAnalyzerLiveSession {
            Task { await session.cancel() }
        }

        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        speechAnalyzerSession = nil
        speechAnalyzerConverter = nil
        isRunning = false

        audioSessionManager.deactivate()

        print("[iOSLiveTranscriber] Cancelled")
    }

    // MARK: - Private

    private func setupInterruptionHandling() {
        audioSessionManager.addInterruptionObserver(owner: self) { [weak self] began in
            Task { @MainActor in
                if began {
                    self?.handleInterruption()
                }
            }
        }
    }

    private func handleInterruption() {
        guard isRunning else { return }

        print("[iOSLiveTranscriber] Handling interruption")
        error = iOSTranscriptionError.interrupted
        onError?(iOSTranscriptionError.interrupted)

        // Stop but preserve what we have
        Task {
            _ = await stop()
        }
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == Self.assistantErrorDomain,
               nsError.code == Self.cancelledTaskErrorCode,
               isShuttingDownRecognitionTask || !isRunning {
                return
            }
            // Commit any in-progress text before propagating the error so a
            // silence-timeout error doesn't silently drop the user's dictation.
            if !isShuttingDownRecognitionTask, !lastFormattedString.isEmpty {
                committedText = [committedText, lastFormattedString]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                lastFormattedString = ""
            }
            print("[iOSLiveTranscriber] Recognition error: \(error.localizedDescription)")
            self.error = iOSTranscriptionError.recognitionFailed(error)
            onError?(self.error!)
            return
        }
        guard let result = result else { return }

        isShuttingDownRecognitionTask = false
        latestResult = result
        let currentText = result.bestTranscription.formattedString
        let resultIsFinal = result.isFinal

        // Detect implicit text reset (Apple silently clears after a pause)
        commitIfImplicitReset(currentText: currentText, isFinal: resultIsFinal)
        lastFormattedString = currentText

        // Build display text from committed + current
        let displayText = [committedText, currentText]
            .filter { !$0.isEmpty }.joined(separator: " ")

        // Calculate confidence
        let avgConfidence: Double? = result.bestTranscription.segments.isEmpty
            ? nil
            : result.bestTranscription.segments.map {
                Double($0.confidence)
            }.reduce(0, +) / Double(result.bestTranscription.segments.count)

        // Update state
        partialText = displayText
        self.isFinal = resultIsFinal
        self.confidence = avgConfidence

        // Callback
        onPartialResult?(displayText, resultIsFinal)

        if resultIsFinal {
            print("[iOSLiveTranscriber] Mid-session isFinal – "
                  + "committing \(displayText.count) chars, restarting")
            committedText = displayText
            lastFormattedString = ""
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
        print("[iOSLiveTranscriber] Implicit text reset – "
              + "committing \(lastFormattedString.count) chars")
        committedText = [committedText, lastFormattedString]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Restart recognition after a mid-session `isFinal` so continued speech
    /// is captured without losing previously committed text.
    private func restartRecognitionTask() {
        guard isRunning, let recognizer = speechRecognizer else { return }

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

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if preferOnDevice && recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        recognitionRequest = newRequest
        latestResult = nil
        lastFormattedString = ""

        // Reinstall the tap so its closure captures the new request; the old
        // tap holds the previous (cancelled) request immutably.
        audioEngine.inputNode.removeTap(onBus: 0)
        installTap(appendingTo: newRequest)

        recognitionTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result, error: error)
            }
        }
    }
    private func appendLatestSegments() {
        guard let latestResult else { return }
        accumulatedSegments.append(contentsOf: mappedSegments(from: latestResult))
    }

    private func mappedSegments(from result: SFSpeechRecognitionResult) -> [TranscriptionSegment] {
        result.bestTranscription.segments.map { segment in
            TranscriptionSegment(
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration,
                text: segment.substring,
                isFinal: true,
                confidence: Double(segment.confidence)
            )
        }
    }
    private func buildFinalResult(duration: TimeInterval) -> TranscriptionResult {
        let latestSegments = latestResult.map(mappedSegments(from:)) ?? []
        let finalSegments = accumulatedSegments + latestSegments

        // partialText already includes committedText from previous segments
        return TranscriptionResult(
            text: partialText,
            segments: finalSegments,
            confidence: confidence,
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
