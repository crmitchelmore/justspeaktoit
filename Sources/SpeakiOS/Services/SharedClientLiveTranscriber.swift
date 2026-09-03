#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import os.log

// swiftlint:disable file_length
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
    private let keywords: [String]

    private var client: StreamingTranscriptionClient?
    private let audioEngine = AVAudioEngine()
    private var startTime: Date?
    /// Finalised text so far, folded by the hosted client's declared final
    /// shape once `start()` knows which client is in use (issue #700).
    private var accumulated = TranscriptAccumulator(shape: .standaloneSegments)

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
    /// The resampler retained for the whole session, plus its end-of-stream
    /// flush (issue #872). Built on `start()` before the tap is installed and
    /// only touched on `audioProcessingQueue` after that, so it needs no lock.
    private let converterCache = LiveConverterCache()
    /// Audio handed to the client that no response has accounted for yet — set
    /// on the audio-processing queue, read and cleared on the main actor, so it
    /// carries its own lock (issue #641: the short-utterance loss).
    private let unansweredAudio = UnansweredAudioSignal()

    public init(
        route: LiveTranscriptionRoute,
        apiKey: String,
        language: String? = Locale.current.identifier,
        keywords: [String] = [],
        audioSessionManager: AudioSessionManager
    ) {
        self.route = route
        self.apiKey = apiKey
        self.language = language
        self.keywords = keywords
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
            for: route, apiKey: apiKey, language: language, keywords: keywords
        ) else {
            let err = LiveTranscriptionClientError.providerNotAvailable(route.provider)
            self.error = err
            throw err
        }

        SpeakLogger.logTranscription(event: "start", model: route.modelID)

        try await ensureMicrophonePermission()
        try await configureAudioSession()

        self.client = client
        // Fold finals by the client's declared shape: standalone segments
        // append (identical text repeats included), cumulative finals replace.
        accumulated = TranscriptAccumulator(shape: client.finalShape)
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
        // The retained resampler is still holding the frames whose filter
        // window has not closed. Flush them down the same send path the live
        // chunks use, before the client is finalised, or the tail of a short
        // utterance is dropped (issue #872).
        await drainConverterTail()
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
        // Cancelled audio is thrown away, so there is nothing to drain — just
        // drop the converter so the next session builds a fresh one.
        converterCache.reset()
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
        guard StreamingFinalisationPolicy.shouldAwaitFinalisation(
            finishFlushesBufferedAudio: finalizingClient.finishFlushesBufferedAudio,
            hasUnfinalisedTranscript: partialText != accumulated.text,
            hasUnansweredAudio: unansweredAudio.isSet
        ) else {
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
        unansweredAudio.clear()
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
        // The provider has answered for everything sent so far; anything
        // captured after this point becomes outstanding again.
        unansweredAudio.clear()
        if isFinal {
            // Folds by the client's declared final shape: standalone segments
            // append (repeated identical text is a genuine repeat), cumulative
            // finals replace (issue #700).
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
        // The cache owns the converter for the session: it is reused for every
        // tap buffer (never `reset()` between chunks, which would wipe the
        // resampler's filter history) and flushed at stop by
        // `drainConverterTail()`.
        ), let converter = converterCache.converter(from: nativeFormat, to: targetFormat) else {
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
        guard status != .error, let data = Self.pcm16Data(from: outputBuffer) else { return }
        guard let client else { return }
        unansweredAudio.record()
        client.sendAudio(data)
    }

    /// Flushes the retained resampler's trailing frames down the same send path
    /// the live chunks use, then releases the converter (issue #872).
    ///
    /// Hops through `audioProcessingQueue` so the tail lands strictly after the
    /// last queued tap chunk and strictly before the client is finalised —
    /// mirroring the `queue.sync` drain in the macOS controllers.
    func drainConverterTail() async {
        let client = self.client
        let cache = converterCache
        let unansweredAudio = self.unansweredAudio
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioProcessingQueue.async {
                defer { continuation.resume() }
                // Drain unconditionally: the converter is released either way,
                // so a session that lost its client still starts clean.
                let tail = cache.drain()
                guard let client, let tail, let data = Self.pcm16Data(from: tail) else { return }
                unansweredAudio.record()
                client.sendAudio(data)
            }
        }
    }

    /// Float32 mono frames → little-endian PCM16 bytes, the wire format the
    /// shared clients expect.
    nonisolated static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        var samples = [Int16](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, channelData[index]))
            samples[index] = Int16(clamped * Float(Int16.max))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

#endif
