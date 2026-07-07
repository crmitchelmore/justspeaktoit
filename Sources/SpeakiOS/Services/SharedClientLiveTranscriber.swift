#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import os.log

/// Generic iOS live transcriber that drives **any** ``StreamingTranscriptionClient``.
///
/// It captures microphone audio with `AVAudioEngine`, converts it to linear16
/// mono PCM at the provider's expected sample rate, and streams it to a client
/// built by ``LiveTranscriptionClientFactory``. This is the single iOS capture
/// path for every provider whose client lives in `SpeakCore`, so adding a new
/// provider needs only its shared client + a factory case — no new iOS wiring.
@MainActor
public final class SharedClientLiveTranscriber: ObservableObject {
    @Published private(set) public var isRunning = false
    @Published private(set) public var partialText = ""
    @Published private(set) public var finalText = ""
    @Published private(set) public var error: Error?

    public var onPartialResult: ((String, Bool) -> Void)?
    public var onError: ((Error) -> Void)?

    private let audioSessionManager: AudioSessionManager
    private let route: LiveTranscriptionRoute
    private let apiKey: String
    private let language: String?

    private var client: StreamingTranscriptionClient?
    private let audioEngine = AVAudioEngine()
    private var startTime: Date?
    private var accumulatedText = ""

    public init(
        route: LiveTranscriptionRoute,
        apiKey: String,
        language: String? = Locale.current.identifier,
        audioSessionManager: AudioSessionManager
    ) {
        self.route = route
        self.apiKey = apiKey
        self.language = language
        self.audioSessionManager = audioSessionManager
        setupInterruptionHandling()
    }

    public func start() async throws {
        guard !isRunning else { return }

        guard let client = LiveTranscriptionClientFactory.makeClient(
            for: route, apiKey: apiKey, language: language
        ) else {
            let err = LiveTranscriptionClientError.providerNotAvailable(route.provider)
            self.error = err
            throw err
        }

        SpeakLogger.logTranscription(event: "start", model: route.modelID)

        try await ensureMicrophonePermission()
        try await configureAudioSession()

        self.client = client
        client.start(
            onTranscript: { [weak self] text, isFinal in
                Task { @MainActor in self?.handleTranscript(text: text, isFinal: isFinal) }
            },
            onError: { [weak self] error in
                Task { @MainActor in self?.handleError(error) }
            }
        )

        try startAudioEngine()
        resetState()
    }

    public func stop() async -> TranscriptionResult {
        let text = accumulatedText.isEmpty ? partialText : accumulatedText
        guard isRunning else {
            return makeResult(text: text, duration: 0)
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        client?.stop()
        client = nil
        isRunning = false
        audioSessionManager.deactivate()

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let result = makeResult(text: text, duration: duration)
        SpeakLogger.logTranscription(
            event: "stop", model: route.modelID,
            wordCount: result.text.split(separator: " ").count
        )
        return result
    }

    public func cancel() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        client?.stop()
        client = nil
        isRunning = false
        audioSessionManager.deactivate()
    }

    // MARK: - Private

    private func makeResult(text: String, duration: TimeInterval) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            segments: [],
            confidence: nil,
            duration: duration,
            modelIdentifier: route.modelID,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    private func ensureMicrophonePermission() async throws {
        if !audioSessionManager.hasMicrophonePermission() {
            let granted = await audioSessionManager.requestMicrophonePermission()
            if !granted {
                let err = iOSTranscriptionError.permissionDenied(.microphone)
                self.error = err
                throw err
            }
        }
    }

    private func configureAudioSession() async throws {
        do {
            try await audioSessionManager.configureForRecording()
        } catch {
            let wrapped = iOSTranscriptionError.audioSessionFailed(error)
            self.error = wrapped
            throw wrapped
        }
    }

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let (targetFormat, converter) = try makeConverter(from: nativeFormat)
        let sampleRate = Double(route.sampleRate)
        let client = self.client

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            self?.convertAndSend(
                buffer: buffer, nativeFormat: nativeFormat,
                targetFormat: targetFormat, converter: converter,
                sampleRate: sampleRate, client: client
            )
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func makeConverter(
        from nativeFormat: AVAudioFormat
    ) throws -> (AVAudioFormat, AVAudioConverter) {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(route.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            let err = iOSTranscriptionError.audioSessionFailed(
                NSError(domain: "SharedClientLiveTranscriber", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to build audio converter"])
            )
            self.error = err
            throw err
        }
        return (targetFormat, converter)
    }

    private nonisolated func convertAndSend(
        buffer: AVAudioPCMBuffer,
        nativeFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        sampleRate: Double,
        client: StreamingTranscriptionClient?
    ) {
        let ratio = sampleRate / nativeFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channelData = outputBuffer.floatChannelData?[0] else { return }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }
        var samples = [Int16](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, channelData[index]))
            samples[index] = Int16(clamped * Float(Int16.max))
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        client?.sendAudio(data)
    }

    private func resetState() {
        partialText = ""
        finalText = ""
        accumulatedText = ""
        error = nil
        startTime = Date()
        isRunning = true
    }

    private func setupInterruptionHandling() {
        audioSessionManager.onInterruption = { [weak self] began in
            Task { @MainActor in
                guard began, let self, self.isRunning else { return }
                self.error = iOSTranscriptionError.interrupted
                self.onError?(iOSTranscriptionError.interrupted)
                _ = await self.stop()
            }
        }
    }

    private func handleTranscript(text: String, isFinal: Bool) {
        if isFinal {
            if !accumulatedText.isEmpty { accumulatedText += " " }
            accumulatedText += text
            finalText = accumulatedText
            partialText = accumulatedText
        } else {
            partialText = accumulatedText.isEmpty ? text : accumulatedText + " " + text
        }
        onPartialResult?(text, isFinal)
    }

    private func handleError(_ error: Error) {
        self.error = error
        onError?(error)
    }
}
#endif
