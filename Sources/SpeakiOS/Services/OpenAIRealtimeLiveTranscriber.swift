#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "OpenAIRealtimeLiveTranscriber")

// swiftlint:disable file_length

private let openAIRealtimeOutputBufferPool = OpenAIRealtimePCMBufferPool(maximumBuffers: 2)

private final class OpenAIRealtimePCMBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBuffers: Int
    private var buffers: [AVAudioPCMBuffer] = []

    init(maximumBuffers: Int) {
        self.maximumBuffers = maximumBuffers
    }

    func buffer(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if let index = buffers.firstIndex(where: { $0.format == format && $0.frameCapacity >= frameCapacity }) {
            let buffer = buffers.remove(at: index)
            buffer.frameLength = 0
            return buffer
        }

        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
    }

    func recycle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard buffers.count < maximumBuffers else { return }
        buffer.frameLength = 0
        buffers.append(buffer)
    }
}

/// iOS live transcriber backed by OpenAI's Realtime API in transcription mode.
///
/// Mirrors the macOS `OpenAIRealtimeLiveTranscriber` / `OpenAIRealtimeLiveController`
/// pair, collapsed into a single `ObservableObject` to match the existing
/// iOS provider shape (`SharedClientLiveTranscriber`, `iOSLiveTranscriber`).
///
/// Endpoint: `wss://api.openai.com/v1/realtime?intent=transcription`.
/// All Realtime transcription models use this GA transcription session shape;
/// `?model=<name>` creates a conversation session and rejects transcription
/// updates.
/// Audio: PCM16 mono @ 24 kHz, base64 in `input_audio_buffer.append`.
/// On stop we wait for the session config ack, flush, send
/// `input_audio_buffer.commit`, then wait for the final `.completed` event
/// or `postStopFinalizeBudget` (0.5 s) — whichever comes first.
@MainActor
// swiftlint:disable:next type_body_length
public final class OpenAIRealtimeLiveTranscriber: ObservableObject {
    // MARK: - Published State

    @Published public private(set) var isRunning = false
    @Published public private(set) var partialText = ""
    @Published public private(set) var finalText = ""
    @Published public private(set) var error: Error?

    // MARK: - Configuration

    public var language: String? = Locale.current.language.languageCode?.identifier
    /// Catalogue id like `openai/gpt-live-transcribe-streaming`. The
    /// `-streaming` suffix is stripped before being sent to OpenAI.
    public var modelID: String = "gpt-realtime-whisper-streaming"

    // MARK: - Callbacks

    public var onPartialResult: ((String, Bool) -> Void)?
    public var onFinalResult: ((TranscriptionResult) -> Void)?
    public var onError: ((Error) -> Void)?
    /// Raised on the main actor at most once per start, when this run's own
    /// input tap accepts a buffer with a positive frame count (issue #983).
    public var onFirstInputBuffer: (() -> Void)?
    /// Local startup-boundary observations for this start (issue #972).
    public var onStartupObservation: ((StartupObservation) -> Void)?

    // MARK: - Private

    private let audioSessionManager: AudioSessionManager
    private let startup = RecordingStartupOperation()
    private var ownsAudioSession = false
    private var hasInputTap = false
    /// Replaced per start so a retired run's tap can never report input for
    /// the run that replaced it.
    private var firstInputSignal = FirstInputSignal()

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
    private let audioEngine = AVAudioEngine()
    private let configurationObserver = CaptureDisruptionObserver()
    private let captureInterruptionObserver = CaptureDisruptionObserver()
    private var apiKey: String?
    private var makeClient: (() -> OpenAIRealtimeWebSocketClient)?
    private var startCaptureOverride: ((AudioRecordingPersistence) throws -> Void)?
    private var startTime: Date?
    private var transcriber: OpenAIRealtimeWebSocketClient?
    /// The resampler retained for the whole session, plus its end-of-stream
    /// flush (issue #872). Built on `start()` before the tap is installed and
    /// only touched on `audioProcessingQueue` after that, so it needs no lock.
    private let converterCache = LiveConverterCache()
    private static let targetSampleRate: Double = 24_000

    /// Per-segment bookkeeping keyed by `item_id`. Mirrors the macOS
    /// controller — keeps stable order for multi-segment commits.
    private var itemOrder: [String] = []
    private var finalsByItem: [String: String] = [:]
    private var currentDeltasByItem: [String: String] = [:]
    /// Item ids that completed *before* the user pressed stop. We only
    /// resume the stop continuation on a *new* completion — typically the
    /// one triggered by our explicit commit.
    private var preStopCompletedItemIDs: Set<String> = []
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var hasFinishedStopping = false
    private var isStopping = false
    private var activeCaptureID: UUID?
    // Injectable capture/transport boundaries; production owns the engine and socket.
    var startCaptureAudio: (() throws -> Void)?
    var connectRealtimeClient: ((String) -> Void)?

    /// Persistent audio recorder — saves audio to disk alongside transcription.
    public let audioRecorder = AudioRecordingPersistence()
    let recordingLoss = RecordingLossReporting()

    /// Serial queue that takes tap buffers off the real-time audio thread —
    /// persistence, resampling, and the base64/JSON encode inside
    /// `sendAudio` all run here instead of in the tap callback.
    private let audioProcessingQueue = DispatchQueue(label: "com.speak.ios.openairealtime.audioProcessing")
    /// Pool for tap-buffer copies so the hot path never allocates.
    private let tapBufferPool = PCMBufferPool(maximumBuffers: 4)

    // MARK: - Init

    public init(audioSessionManager: AudioSessionManager) {
        self.audioSessionManager = audioSessionManager
    }

    /// Allows lifecycle tests to supply PCM and acknowledgement timing without a microphone or network.
    convenience init(
        audioSessionManager: AudioSessionManager,
        makeClient: @escaping () -> OpenAIRealtimeWebSocketClient,
        startCapture: @escaping (AudioRecordingPersistence) throws -> Void
    ) {
        self.init(audioSessionManager: audioSessionManager)
        self.makeClient = makeClient
        self.startCaptureOverride = startCapture
    }

    // MARK: - Public API

    public func configure(apiKey: String) {
        self.apiKey = apiKey
    }

    public var isConfigured: Bool {
        apiKey?.isEmpty == false
    }

    public func start() async throws {
        guard !isRunning, !isStopping, !startup.isStarting else { return }
        do {
            try await startup.run(
                { try await self.startCapture() },
                onFailure: { self.cleanupCapture() }
            )
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private func startCapture() async throws {
        firstInputSignal = FirstInputSignal()
        recordingLoss.begin(recorder: audioRecorder)
        SpeakLogger.logTranscription(event: "start", model: "openai/\(modelID)")

        guard let apiKey, !apiKey.isEmpty else {
            let err = OpenAIRealtimeError.missingAPIKey
            SpeakLogger.logError(err, context: "OpenAIRealtimeLiveTranscriber.start", logger: SpeakLogger.transcription)
            self.error = err
            throw err
        }

        if let startCaptureOverride {
            connectClient(apiKey: apiKey)
            resetState()
            try startCaptureOverride(audioRecorder)
            return
        }

        try await ensureMicrophonePermission()
        try Task.checkCancellation()
        ownsAudioSession = true
        try await configureAudioSession()
        try Task.checkCancellation()
        if startCaptureAudio == nil { connectClient(apiKey: apiKey) }
        do {
            if let startCaptureAudio {
                try startCaptureAudio()
            } else {
                try startAudioEngine()
            }
        } catch {
            transcriber?.stop()
            transcriber = nil
            throw error
        }
        resetState()
        observeCaptureConfiguration()

        logger.info("Started")
    }

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
        let lossRun = recordingLoss.currentReport
        guard isRunning, !hasFinishedStopping else {
            return emptyResult()
        }

        hasFinishedStopping = true
        isStopping = true
        defer { isStopping = false }
        audioEngine.stop()
        removeInputTap()

        // Buffers handed to the queue just before the tap came off are still
        // being written and sent; let them land before the input buffer is
        // committed and the recorder is closed.
        await audioProcessingQueue.drainPendingWork()

        preStopCompletedItemIDs = Set(finalsByItem.keys)

        // The retained resampler is still holding the frames whose filter
        // window has not closed. Flush them down the same send path the live
        // chunks use, before the input buffer is committed, or the tail of a
        // short utterance never reaches the model (issue #872).
        await drainConverterTail(to: transcriber)

        if let client = transcriber {
            await finalizeRemoteSession(client)
        }
        transcriber = nil

        recordingLoss.finish(recorder: audioRecorder, run: lossRun)

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let text = composedTranscript()

        let result = TranscriptionResult(
            text: text,
            segments: [],
            confidence: nil,
            duration: duration,
            modelIdentifier: "openai/\(modelID)",
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )

        isRunning = false
        activeCaptureID = nil
        releaseAudioSession()

        SpeakLogger.logTranscription(
            event: "stop",
            model: "openai/\(modelID)",
            wordCount: result.text.split(separator: " ").count
        )
        onFinalResult?(result)

        return result
    }

    /// Flushes the retained resampler's trailing frames down the same send path
    /// the live chunks use, then releases the converter (issue #872).
    ///
    /// Hops through `audioProcessingQueue` so the tail lands strictly after the
    /// last queued tap chunk and strictly before the commit — mirroring the
    /// `queue.sync` drain in the macOS controllers. The target format is
    /// already PCM16 at 24 kHz, so the drained bytes go out as-is.
    private func drainConverterTail(to client: OpenAIRealtimeWebSocketClient?) async {
        let cache = converterCache
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioProcessingQueue.async {
                defer { continuation.resume() }
                // Drain unconditionally: the converter is released either way,
                // so a session that lost its client still starts clean.
                let tail = cache.drainPCM16()
                guard let client, let tail else { return }
                client.sendAudio(tail)
            }
        }
    }

    /// Stop sequence that must run while we still have a live WebSocket client:
    /// 1. Await session-ready (config ack) so any pre-ready buffered audio
    ///    is dispatched correctly (or the timeout lapses).
    /// 2. Await pending audio sends.
    /// 3. Send commit.
    /// 4. Await the commit's send to complete before starting the finalize
    ///    budget — otherwise the budget can elapse before the server has
    ///    even seen our commit.
    /// 5. Wait for a *new* completed event or the budget, whichever comes
    ///    first.
    /// 6. Close the socket.
    private func finalizeRemoteSession(_ client: OpenAIRealtimeWebSocketClient) async {
        _ = await client.awaitSessionReady(timeout: 1.0)
        await client.waitForPendingSends()
        client.commitInputBuffer()
        await client.waitForPendingSends()

        let budget: TimeInterval = 0.5
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
            // Capture continuation explicitly so a deallocated transcriber
            // never leaks an unresumed continuation. We also identity-check
            // against `stopContinuation` to avoid double-resuming if a real
            // .completed event already fired before the budget elapsed.
            Task(priority: .userInitiated) { [weak self, continuation] in
                try? await Task.sleep(for: .seconds(budget))
                guard let self else {
                    continuation.resume()
                    return
                }
                guard let cont = self.stopContinuation else { return }
                self.stopContinuation = nil
                cont.resume()
            }
        }

        client.stop()
    }

    private func emptyResult() -> TranscriptionResult {
        TranscriptionResult(
            text: composedTranscript(),
            segments: [],
            confidence: nil,
            duration: 0,
            modelIdentifier: "openai/\(modelID)",
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    public func cancel() {
        configurationObserver.stop()
        captureInterruptionObserver.stop()
        startup.cancel()
        cleanupCapture()
    }

    private func cleanupCapture() {
        configurationObserver.stop()
        captureInterruptionObserver.stop()
        recordingLoss.cancel()
        guard isRunning || ownsAudioSession || hasInputTap else { return }

        audioEngine.stop()
        removeInputTap()
        audioProcessingQueue.sync {}
        transcriber?.stop()
        transcriber = nil
        // Cancelled audio is thrown away, so there is nothing to drain — just
        // drop the converter so the next session builds a fresh one.
        converterCache.reset()

        audioRecorder.cancelRecording()

        isRunning = false
        activeCaptureID = nil
        releaseAudioSession()

        logger.info("Cancelled")
    }

    // MARK: - Private

    private func ensureMicrophonePermission() async throws {
        if !audioSessionManager.hasMicrophonePermission() {
            let granted = await audioSessionManager.requestMicrophonePermission()
            try Task.checkCancellation()
            if !granted {
                let err = iOSTranscriptionError.permissionDenied(.microphone)
                SpeakLogger.logError(err, context: "Microphone permission", logger: SpeakLogger.audio)
                self.error = err
                throw err
            }
        }
    }

    private func configureAudioSession() async throws {
        do {
            try await audioSessionManager.configureForRecording()
            onStartupObservation?(.stage(.audioSessionConfigured))
            SpeakLogger.audio.info("Audio session configured for OpenAI Realtime")
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let wrapped = iOSTranscriptionError.audioSessionFailed(error)
            SpeakLogger.logError(wrapped, context: "Audio session setup", logger: SpeakLogger.audio)
            self.error = wrapped
            throw wrapped
        }
    }

    private func connectClient(apiKey: String) {
        let captureID = UUID()
        activeCaptureID = captureID
        if let connectRealtimeClient {
            connectRealtimeClient(apiKey)
            return
        }
        let realtimeName = Self.realtimeModelName(from: modelID)
        let client = makeClient?() ?? OpenAIRealtimeWebSocketClient(
            apiKey: apiKey,
            model: realtimeName,
            language: language.map(Self.extractLanguageCode(from:)),
            sampleRate: Int(Self.targetSampleRate)
        )
        transcriber = client
        SpeakLogger.network.info("Connecting to OpenAI Realtime streaming API")
        client.start(
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard self?.activeCaptureID == captureID else { return }
                    self?.handleEvent(event)
                }
            },
            onError: { [weak self] err in
                Task { @MainActor in
                    guard self?.activeCaptureID == captureID else { return }
                    self?.handleError(err)
                }
            }
        )
    }

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let (target, conv) = try createAudioConverter(from: nativeFormat)
        let client = transcriber
        let signal = firstInputSignal
        let captureID = activeCaptureID

        // The safety writer opens before the tap and the engine, so the file
        // covers the very first buffers instead of starting a beat late
        // (issue #992); a writer failure is reported, never fatal (issue #950).
        recordingLoss.startWriter(audioRecorder, format: nativeFormat)
        let lossReport = recordingLoss.currentReport
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            // Copy the buffer and hop off the real-time audio thread —
            // heavy work in the tap makes CoreAudio drop mic buffers.
            guard let self, let copied = lossReport.copyCapture(buffer, using: self.tapBufferPool) else { return }
            if copied.frameLength > 0, let captureID, signal.markObserved() {
                Task { @MainActor [weak self] in self?.reportFirstInputBuffer(captureID) }
            }
            self.audioProcessingQueue.async {
                defer { self.tapBufferPool.recycle(copied) }
                self.audioRecorder.writeBuffer(copied)
                self.convertAndSendAudio(
                    buffer: copied,
                    nativeFormat: nativeFormat,
                    targetFormat: target,
                    converter: conv,
                    client: client
                )
            }
        }
        hasInputTap = true

        audioEngine.prepare()
        try audioEngine.start()
        // Only after the engine actually returned.
        onStartupObservation?(.stage(.engineStarted))
    }

    private func createAudioConverter(
        from nativeFormat: AVAudioFormat
    ) throws -> (AVAudioFormat, AVAudioConverter) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            let err = iOSTranscriptionError.audioSessionFailed(
                NSError(domain: "OpenAIRealtimeLiveTranscriber", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format"])
            )
            self.error = err
            throw err
        }
        // The cache owns the converter for the session: it is reused for every
        // tap buffer (never `reset()` between chunks, which would wipe the
        // resampler's filter history) and flushed at stop by
        // `drainConverterTail(to:)`.
        guard let conv = converterCache.converter(from: nativeFormat, to: target) else {
            let err = iOSTranscriptionError.audioSessionFailed(
                NSError(domain: "OpenAIRealtimeLiveTranscriber", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
            )
            self.error = err
            throw err
        }
        return (target, conv)
    }

    private nonisolated func convertAndSendAudio(
        buffer: AVAudioPCMBuffer,
        nativeFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        client: OpenAIRealtimeWebSocketClient?
    ) {
        let ratio = Self.targetSampleRate / nativeFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = openAIRealtimeOutputBufferPool.buffer(
            format: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return
        }
        defer { openAIRealtimeOutputBufferPool.recycle(outputBuffer) }
        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
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
        guard status != .error,
              let int16Channel = outputBuffer.int16ChannelData?[0] else { return }
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }
        let byteCount = frameCount * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Channel, count: byteCount)
        client?.sendAudio(data)
    }

    private func resetState() {
        partialText = ""
        finalText = ""
        error = nil
        startTime = Date()
        itemOrder = []
        finalsByItem = [:]
        currentDeltasByItem = [:]
        preStopCompletedItemIDs = []
        hasFinishedStopping = false
        stopContinuation = nil
        isRunning = true
    }

    private func handleEvent(_ event: OpenAIRealtimeWebSocketClient.Event) {
        switch event {
        case .sessionCreated:
            SpeakLogger.transcription.info("OpenAI Realtime session created (awaiting config ack)")
        case .sessionReady:
            SpeakLogger.transcription.info("OpenAI Realtime session ready (config applied)")
        case .delta(let text, let itemId):
            let key = itemId.isEmpty ? "_pending" : itemId
            if currentDeltasByItem[key] == nil, finalsByItem[key] == nil {
                itemOrder.append(key)
            }
            currentDeltasByItem[key, default: ""].append(text)
            partialText = composedTranscript()
            onPartialResult?(partialText, false)
        case .completed(let transcript, let itemId):
            let key = itemId.isEmpty ? "_pending" : itemId
            let isNewItem = !preStopCompletedItemIDs.contains(key)
            if currentDeltasByItem[key] == nil, finalsByItem[key] == nil {
                itemOrder.append(key)
            }
            finalsByItem[key] = transcript
            currentDeltasByItem.removeValue(forKey: key)
            partialText = composedTranscript()
            finalText = composedTranscript()
            onPartialResult?(partialText, true)

            if hasFinishedStopping, isNewItem, let cont = stopContinuation {
                stopContinuation = nil
                cont.resume()
            }
        }
    }

    private func handleError(_ err: Error) {
        // Preserve the first explicit loss notice through finalisation failures.
        if case .preReadyAudioOverflow? = error as? OpenAIRealtimeError { return }
        error = err
        onError?(err)
    }

    private func composedTranscript() -> String {
        itemOrder.compactMap { key in
            finalsByItem[key] ?? currentDeltasByItem[key]
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    /// Translate catalogue id `openai/gpt-realtime-whisper-streaming` (or
    /// already-stripped `gpt-realtime-whisper-streaming`) to the OpenAI API
    /// model name `gpt-realtime-whisper`.
    static func realtimeModelName(from modelID: String) -> String {
        OpenAITranscriptionModels.apiModelName(from: modelID)
    }

    /// Normalises a BCP-47 locale identifier (e.g. "en-GB", "en_US") to the
    /// ISO-639-1 two-letter code OpenAI Realtime expects (e.g. "en"). Mirrors
    /// the helper used by the macOS provider.
    static func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }
}

#endif
