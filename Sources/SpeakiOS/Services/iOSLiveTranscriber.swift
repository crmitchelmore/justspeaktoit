#if os(iOS)
import AVFoundation
import Foundation
import Speech
import SpeakCore
import os.log

/// Error types for iOS live transcription.
public enum iOSTranscriptionError: LocalizedError {
    case permissionDenied(Permission)
    case recognizerUnavailable
    case audioSessionFailed(Error)
    case recognitionFailed(Error)
    case interrupted
    
    public enum Permission {
        case microphone
        case speechRecognition
    }
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied(.microphone):
            return "Microphone permission is required for transcription."
        case .permissionDenied(.speechRecognition):
            return "Speech recognition permission is required."
        case .recognizerUnavailable:
            return "Speech recognizer is not available for the selected language."
        case .audioSessionFailed(let error):
            return "Failed to configure audio: \(error.localizedDescription)"
        case .recognitionFailed(let error):
            return "Recognition failed: \(error.localizedDescription)"
        case .interrupted:
            return "Transcription was interrupted (e.g., by a phone call)."
        }
    }
}

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
        
        // Create speech recognizer for locale
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable else {
            SpeakLogger.transcription.error("Speech recognizer unavailable for language: \(self.language, privacy: .public)")
            throw iOSTranscriptionError.recognizerUnavailable
        }
        speechRecognizer = recognizer
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            throw iOSTranscriptionError.recognizerUnavailable
        }
        
        request.shouldReportPartialResults = true
        
        // Prefer on-device recognition if available
        if preferOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            SpeakLogger.transcription.info("Using on-device recognition")
        } else {
            SpeakLogger.transcription.info("Using server-based recognition")
        }
        
        // Setup audio engine
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            self?.audioRecorder.writeBuffer(buffer)
        }
        
        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        // Start persistent recording alongside transcription
        try? audioRecorder.startRecording(format: recordingFormat)
        
        // Reset state
        partialText = ""
        isFinal = false
        confidence = nil
        error = nil
        latestResult = nil
        segments = []
        startTime = Date()
        
        // Start recognition
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result, error: error)
            }
        }
        
        isRunning = true
        print("[iOSLiveTranscriber] Started")
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
            print("[iOSLiveTranscriber] Recognition error: \(error.localizedDescription)")
            self.error = iOSTranscriptionError.recognitionFailed(error)
            onError?(self.error!)
            return
        }
        
        guard let result = result else { return }
        
        latestResult = result
        let text = result.bestTranscription.formattedString
        let isFinal = result.isFinal
        
        // Calculate confidence
        let avgConfidence: Double? = result.bestTranscription.segments.isEmpty
            ? nil
            : result.bestTranscription.segments.map { Double($0.confidence) }.reduce(0, +) / Double(result.bestTranscription.segments.count)
        
        // Update state
        partialText = text
        self.isFinal = isFinal
        self.confidence = avgConfidence
        
        // Callback
        onPartialResult?(text, isFinal)
        
        if isFinal {
            print("[iOSLiveTranscriber] Final result received")
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
