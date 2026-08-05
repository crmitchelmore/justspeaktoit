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
/// path for every provider whose client lives in `SpeakCore` — Deepgram and
/// ElevenLabs included — so adding a new provider needs only its shared client
/// + a factory case, with no new iOS wiring. Anything genuinely per-provider
/// (sample rate, API model name, stop-grace semantics) is read from the route
/// or the client's own contract rather than branched on here.
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
    /// Finalised text so far, folded from the client's finals.
    private var accumulated = TranscriptAccumulator()

    /// Persistent audio recorder — saves audio to disk alongside transcription,
    /// so a session survives the network dropping mid-stream.
    public let audioRecorder = AudioRecordingPersistence()

    /// Serial queue that takes tap buffers off the real-time audio thread —
    /// persistence and resample + network sends all run here, not in the tap
    /// callback.
    private let audioProcessingQueue = DispatchQueue(label: "com.speak.ios.sharedclient.audioProcessing")
    /// Pools for tap-buffer copies and converter output so the hot path never allocates.
    private let tapBufferPool = PCMBufferPool(maximumBuffers: 4)
    private let outputBufferPool = PCMBufferPool(maximumBuffers: 2)

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

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let err = StreamingClientError.missingAPIKey(provider: route.provider.displayName)
            SpeakLogger.logError(
                err, context: "SharedClientLiveTranscriber.start", logger: SpeakLogger.transcription
            )
            self.error = err
            throw err
        }

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

        do {
            try startAudioEngine()
        } catch {
            // Capture startup failed after the client connected — tear the
            // client and audio session back down so nothing is left running.
            client.stop()
            self.client = nil
            audioSessionManager.deactivate()
            throw error
        }
        resetState()
    }

    public func stop() async -> TranscriptionResult {
        guard isRunning else {
            let text = partialText.isEmpty ? accumulated.text : partialText
            return makeResult(text: text, duration: 0)
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        // Buffers handed to the queue just before the tap came off are still
        // being written and sent; let them land before the client is finalised
        // and the recorder is closed.
        await audioProcessingQueue.drainPendingWork()
        await finishClient()
        _ = audioRecorder.stopRecording()
        isRunning = false
        audioSessionManager.deactivate()

        // `partialText` is the fullest view (finalised text plus any trailing
        // non-final words); fall back to the accumulated finals if empty.
        let text = partialText.isEmpty ? accumulated.text : partialText
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
        // Cancel persistent recording (keeps the partial file).
        audioRecorder.cancelRecording()
        isRunning = false
        audioSessionManager.deactivate()
    }

    // MARK: - Private

    /// Closes the client, giving providers that can still deliver words a
    /// bounded grace period first.
    ///
    /// Providers whose finish flushes buffered audio (Deepgram's `CloseStream`)
    /// always drain, because untranscribed audio can still yield words. For
    /// providers whose finish is only a bounded wait (ElevenLabs), draining
    /// with nothing outstanding would just add latency, so the socket closes
    /// straight away when every interim has already been finalised.
    private func finishClient() async {
        defer { client = nil }
        guard let finalizingClient = client as? FinalizingStreamingTranscriptionClient else {
            client?.stop()
            return
        }
        guard finalizingClient.finishFlushesBufferedAudio || partialText != accumulated.text else {
            finalizingClient.stop()
            return
        }
        // Contract: the return is the session's *full* transcript, not the
        // trailing segment, so it replaces what we accumulated. Appending it
        // would double every word the client already streamed.
        if let finalTranscript = await finalizingClient.finishAndWait(),
           !finalTranscript.isEmpty,
           finalText != finalTranscript {
            applyFullTranscript(finalTranscript)
        }
    }

    /// Adopts a transcript that is already complete (the `finishAndWait()`
    /// return) as the whole session transcript.
    private func applyFullTranscript(_ transcript: String) {
        accumulated.replace(with: transcript)
        finalText = accumulated.text
        partialText = accumulated.text
        onPartialResult?(partialText, true)
    }

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

    private func resetState() {
        partialText = ""
        finalText = ""
        accumulated.reset()
        error = nil
        startTime = Date()
        isRunning = true
    }

    private func setupInterruptionHandling() {
        audioSessionManager.addInterruptionObserver(owner: self) { [weak self] began in
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
            // Providers disagree on whether a final is a standalone segment or
            // the whole utterance so far; `TranscriptAccumulator` folds both
            // shapes the same way the shared clients do.
            accumulated.append(final: text)
            finalText = accumulated.text
            partialText = accumulated.text
        } else {
            partialText = accumulated.display(withInterim: text)
        }
        // Contract: always deliver the full display transcript (accumulated
        // finals plus any trailing partial), matching iOSLiveTranscriber and
        // OpenAIRealtimeLiveTranscriber.
        onPartialResult?(partialText, isFinal)
    }

    private func handleError(_ error: Error) {
        self.error = error
        onError?(error)
    }
}

// MARK: - Audio capture

private extension SharedClientLiveTranscriber {
    func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let (targetFormat, converter) = try makeConverter(from: nativeFormat)
        let sampleRate = Double(route.sampleRate)
        let client = self.client

        let conversion = Conversion(
            targetFormat: targetFormat, converter: converter, targetSampleRate: sampleRate
        )
        let nativeSampleRate = nativeFormat.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            // Copy the buffer and hop off the real-time audio thread —
            // heavy work in the tap makes CoreAudio drop mic buffers.
            guard let self, let copied = self.tapBufferPool.copy(buffer) else { return }
            self.audioProcessingQueue.async {
                defer { self.tapBufferPool.recycle(copied) }
                self.audioRecorder.writeBuffer(copied)
                self.convertAndSend(
                    buffer: copied, nativeSampleRate: nativeSampleRate,
                    conversion: conversion, client: client
                )
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        try? audioRecorder.startRecording(format: nativeFormat)
    }

    /// Bundles the audio-conversion context handed to the capture tap.
    struct Conversion {
        let targetFormat: AVAudioFormat
        let converter: AVAudioConverter
        let targetSampleRate: Double
    }

    func makeConverter(
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

    nonisolated func convertAndSend(
        buffer: AVAudioPCMBuffer,
        nativeSampleRate: Double,
        conversion: Conversion,
        client: StreamingTranscriptionClient?
    ) {
        let ratio = conversion.targetSampleRate / nativeSampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = outputBufferPool.buffer(
            format: conversion.targetFormat, frameCapacity: capacity
        ) else {
            return
        }
        defer { outputBufferPool.recycle(outputBuffer) }
        var conversionError: NSError?
        var didProvideInput = false
        let status = conversion.converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            // One-shot input: returning the same buffer with .haveData again
            // would make the converter duplicate audio frames.
            guard !didProvideInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
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
}

#endif
