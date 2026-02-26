#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import os.log

/// iOS Deepgram live transcriber that integrates with AudioSessionManager.
/// Provides higher accuracy transcription via Deepgram's streaming API.
@MainActor
public final class DeepgramLiveTranscriber: ObservableObject {
    // MARK: - Published State
    
    @Published private(set) public var isRunning = false
    @Published private(set) public var partialText = ""
    @Published private(set) public var finalText = ""
    @Published private(set) public var error: Error?
    
    // MARK: - Configuration
    
    public var language: String = Locale.current.identifier
    public var model: String = "nova-3"
    
    // MARK: - Callbacks
    
    public var onPartialResult: ((String, Bool) -> Void)?
    public var onFinalResult: ((TranscriptionResult) -> Void)?
    public var onError: ((Error) -> Void)?
    
    // MARK: - Private
    
    private let audioSessionManager: AudioSessionManager
    private var deepgramClient: DeepgramLiveClient?
    private let audioEngine = AVAudioEngine()
    private var apiKey: String?
    private var startTime: Date?
    private var accumulatedText = ""

    /// Persistent audio recorder — saves audio to disk alongside transcription.
    public let audioRecorder = AudioRecordingPersistence()
    
    // MARK: - Init
    
    public init(audioSessionManager: AudioSessionManager) {
        self.audioSessionManager = audioSessionManager
        setupInterruptionHandling()
    }
    
    // MARK: - Public API
    
    /// Configure the API key for Deepgram.
    public func configure(apiKey: String) {
        self.apiKey = apiKey
    }
    
    /// Check if API key is configured.
    public var isConfigured: Bool {
        apiKey?.isEmpty == false
    }
    
    /// Start live transcription with Deepgram.
    public func start() async throws {
        guard !isRunning else { return }
        
        SpeakLogger.logTranscription(event: "start", model: "deepgram/\(model)")
        
        guard let apiKey, !apiKey.isEmpty else {
            let error = DeepgramLiveError.missingAPIKey
            SpeakLogger.logError(error, context: "DeepgramLiveTranscriber.start", logger: SpeakLogger.transcription)
            self.error = error
            throw error
        }
        
        // Request microphone permission
        if !audioSessionManager.hasMicrophonePermission() {
            let granted = await audioSessionManager.requestMicrophonePermission()
            if !granted {
                let error = iOSTranscriptionError.permissionDenied(.microphone)
                SpeakLogger.logError(error, context: "Microphone permission", logger: SpeakLogger.audio)
                self.error = error
                throw error
            }
        }
        
        // Configure audio session
        do {
            try audioSessionManager.configureForRecording()
            SpeakLogger.audio.info("Audio session configured for Deepgram")
        } catch {
            let wrappedError = iOSTranscriptionError.audioSessionFailed(error)
            SpeakLogger.logError(wrappedError, context: "Audio session setup", logger: SpeakLogger.audio)
            self.error = wrappedError
            throw wrappedError
        }
        
        // Create Deepgram client
        deepgramClient = DeepgramLiveClient(
            apiKey: apiKey,
            model: model,
            language: language,
            sampleRate: 16000
        )
        
        SpeakLogger.network.info("Connecting to Deepgram streaming API")
        
        // Start Deepgram connection
        deepgramClient?.start(
            onTranscript: { [weak self] text, isFinal in
                Task { @MainActor in
                    self?.handleTranscript(text: text, isFinal: isFinal)
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleError(error)
                }
            }
        )
        
        // Setup audio engine
        let inputNode = audioEngine.inputNode
        
        // Get the native format from the input node - we must use this format for the tap
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        
        // Create a format converter for resampling to 16kHz mono (Deepgram requirement)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            let error = iOSTranscriptionError.audioSessionFailed(
                NSError(domain: "DeepgramLiveTranscriber", code: -1, 
                       userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format"])
            )
            self.error = error
            throw error
        }
        
        // Create converter for resampling
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            let error = iOSTranscriptionError.audioSessionFailed(
                NSError(domain: "DeepgramLiveTranscriber", code: -2, 
                       userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
            )
            self.error = error
            throw error
        }
        
        // Install tap on input node using native format, then convert
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            // Persist raw audio to disk
            self?.audioRecorder.writeBuffer(buffer)

            // Calculate output frame capacity based on sample rate ratio
            let ratio = 16000.0 / nativeFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                return
            }
            
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            guard status != .error, let channelData = outputBuffer.floatChannelData?[0] else {
                return
            }
            
            let frameCount = Int(outputBuffer.frameLength)
            self?.deepgramClient?.sendAudioSamples(channelData, frameCount: frameCount)
        }
        
        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        // Start persistent recording alongside transcription
        try? audioRecorder.startRecording(format: nativeFormat)
        
        // Reset state
        partialText = ""
        finalText = ""
        accumulatedText = ""
        error = nil
        startTime = Date()
        isRunning = true
        
        print("[DeepgramLiveTranscriber] Started")
    }
    
    /// Stop transcription and return final result.
    public func stop() async -> TranscriptionResult {
        guard isRunning else {
            return TranscriptionResult(
                text: finalText.isEmpty ? partialText : finalText,
                segments: [],
                confidence: nil,
                duration: 0,
                modelIdentifier: "deepgram/\(model)",
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }
        
        // Stop audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // Stop Deepgram client
        deepgramClient?.stop()
        deepgramClient = nil

        // Stop persistent recording
        _ = audioRecorder.stopRecording()

        // Build final result
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let text = accumulatedText.isEmpty ? partialText : accumulatedText
        
        let result = TranscriptionResult(
            text: text,
            segments: [],
            confidence: nil,
            duration: duration,
            modelIdentifier: "deepgram/\(model)",
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
        
        isRunning = false
        audioSessionManager.deactivate()
        
        SpeakLogger.logTranscription(event: "stop", model: "deepgram/\(model)", wordCount: result.text.split(separator: " ").count)
        onFinalResult?(result)
        
        return result
    }
    
    /// Cancel transcription without returning result.
    public func cancel() {
        guard isRunning else { return }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        deepgramClient?.stop()
        deepgramClient = nil

        // Cancel persistent recording (keeps partial file)
        audioRecorder.cancelRecording()

        isRunning = false
        
        audioSessionManager.deactivate()
        
        print("[DeepgramLiveTranscriber] Cancelled")
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
        
        print("[DeepgramLiveTranscriber] Handling interruption")
        error = iOSTranscriptionError.interrupted
        onError?(iOSTranscriptionError.interrupted)
        
        Task {
            _ = await stop()
        }
    }
    
    private func handleTranscript(text: String, isFinal: Bool) {
        if isFinal {
            // Accumulate final text
            if !accumulatedText.isEmpty {
                accumulatedText += " "
            }
            accumulatedText += text
            finalText = accumulatedText
            partialText = accumulatedText
        } else {
            // Show partial with accumulated
            if accumulatedText.isEmpty {
                partialText = text
            } else {
                partialText = accumulatedText + " " + text
            }
        }
        
        onPartialResult?(text, isFinal)
    }
    
    private func handleError(_ error: Error) {
        self.error = error
        onError?(error)
    }
}
#endif
