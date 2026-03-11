#if os(iOS)
import AVFoundation
import Foundation
import Speech
import SpeakCore
import os.log

/// iOS-native live transcription using Apple Speech framework.
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
    public var preferOnDevice: Bool = true

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
    private var startTime: Date?
    private var segments: [TranscriptionSegment] = []
    /// Accumulated text from recognition segments finalised mid-session (on pause).
    private var committedText: String = ""
    /// Last `formattedString` received from the recognizer, used to detect
    /// implicit text resets where Apple silently clears the transcript.
    private var lastFormattedString: String = ""

    /// Persistent audio recorder — saves audio to disk alongside transcription.
    public let audioRecorder = AudioRecordingPersistence()

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
            try audioSessionManager.configureForRecording()
            SpeakLogger.audio.info("Audio session configured for recording")
        } catch {
            SpeakLogger.logError(error, context: "Audio session setup", logger: SpeakLogger.audio)
            throw iOSTranscriptionError.audioSessionFailed(error)
        }

        let (recognizer, request) = try setupRecognition()
        try startAudioEngine()
        resetState()

        // Start recognition
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result, error: error)
            }
        }

        isRunning = true
        print("[iOSLiveTranscriber] Started")
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

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            self?.audioRecorder.writeBuffer(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        try? audioRecorder.startRecording(format: recordingFormat)
    }

    private func resetState() {
        partialText = ""
        isFinal = false
        confidence = nil
        error = nil
        latestResult = nil
        segments = []
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
                modelIdentifier: "apple/local/SFSpeechRecognizer",
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }

        // Signal end of audio
        recognitionRequest?.endAudio()

        // Stop audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

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

    /// Cancel transcription without returning result.
    public func cancel() {
        guard isRunning else { return }

        SpeakLogger.transcription.info("Cancelling transcription")

        recognitionRequest?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()

        // Cancel persistent recording (keeps partial file by default)
        audioRecorder.cancelRecording()

        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        isRunning = false

        audioSessionManager.deactivate()

        print("[iOSLiveTranscriber] Cancelled")
    }

    // MARK: - Private

    private func setupInterruptionHandling() {
        audioSessionManager.onInterruption = { [weak self] began in
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
            // Ignore errors from cancelled tasks during restart
            let nsError = error as NSError
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 209 {
                return
            }
            print("[iOSLiveTranscriber] Recognition error: \(error.localizedDescription)")
            self.error = iOSTranscriptionError.recognitionFailed(error)
            onError?(self.error!)
            return
        }

        guard let result = result else { return }

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
              lastFormattedString.count >= 10,
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

        recognitionTask = recognizer.recognitionTask(with: newRequest) {
            [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result, error: error)
            }
        }
    }

    private func buildFinalResult(duration: TimeInterval) -> TranscriptionResult {
        // Build segments from latest result
        var finalSegments: [TranscriptionSegment] = []

        if let result = latestResult {
            finalSegments = result.bestTranscription.segments.map { segment in
                TranscriptionSegment(
                    startTime: segment.timestamp,
                    endTime: segment.timestamp + segment.duration,
                    text: segment.substring,
                    isFinal: true,
                    confidence: Double(segment.confidence)
                )
            }
        }

        // partialText already includes committedText from previous segments
        return TranscriptionResult(
            text: partialText,
            segments: finalSegments,
            confidence: confidence,
            duration: duration,
            modelIdentifier: "apple/local/SFSpeechRecognizer",
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }
}
#endif
