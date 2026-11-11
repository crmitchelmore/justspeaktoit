#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "OpenAIRealtimeLiveTranscriber")

// swiftlint:disable file_length

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
    /// Replaced per start so a retired run's tap can never report input for
    /// the run that replaced it.
    private var firstInputSignal = FirstInputSignal()

    /// Hopped to from the audio thread once, never per buffer.
    private func reportFirstInputBuffer(_ captureID: UUID) {
        guard activeCaptureID == captureID else { return }
        onFirstInputBuffer?()
    }

    private let captureInput: LiveCaptureInput
    private var apiKey: String?
    private var makeClient: (() -> OpenAIRealtimeWebSocketClient)?
    private var startCaptureOverride: ((AudioRecordingPersistence) throws -> Void)?
    private var startTime: Date?
    private var transcriber: OpenAIRealtimeWebSocketClient?
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

    /// Takes tap buffers off the real-time audio thread: persistence,
    /// resampling to PCM16 at 24 kHz and the base64/JSON encode inside
    /// `sendAudio` all run on its serial queue instead of in the tap callback.
    private let audioProcessor = LiveTapPCMProcessor(
        queueLabel: "com.speak.ios.openairealtime.audioProcessing", poolLabel: "ios-openai-realtime"
    )
    /// This run's conversion-failure owner: reported once, text kept.
    private(set) var conversionFailure: LivePCMConversionFailureReport?

    // MARK: - Init

    public init(audioSessionManager: AudioSessionManager) {
        self.audioSessionManager = audioSessionManager
        captureInput = LiveCaptureInput(audioSessionManager: audioSessionManager)
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
        captureInput.armDisruptionHandling { [weak self] in
            guard let self else { return false }
            return self.isRunning && !self.isStopping
        } onStopped: { [weak self] reason in
            // The owner drains the provider and recording once through its normal stop path.
            // Interruption itself is a stopped notice; a real drain failure still reaches onError.
            if !reason.isControlledInterruption { self?.error = reason }
            self?.onError?(reason)
        }
    }

    public func stop() async -> TranscriptionResult {
        captureInput.disarmDisruptionHandling()
        let lossRun = recordingLoss.currentReport
        guard isRunning, !hasFinishedStopping else {
            return emptyResult()
        }

        hasFinishedStopping = true
        isStopping = true
        defer { isStopping = false }
        captureInput.halt()

        // Buffers handed to the queue just before the tap came off are still
        // being written and sent; let them land before the input buffer is
        // committed and the recorder is closed.
        await audioProcessor.drainPendingWork()

        preStopCompletedItemIDs = Set(finalsByItem.keys)

        // The retained resampler is still holding the frames whose filter
        // window has not closed. Flush them down the same send path the live
        // chunks use, before the input buffer is committed, or the tail of a
        // short utterance never reaches the model (issue #872).
        var sendTail: (@Sendable (Data) -> Void)?
        if let tailClient = transcriber { sendTail = { tailClient.sendAudio($0) } }
        await audioProcessor.drainTail(send: sendTail)
        audioProcessor.finishRun()

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
        captureInput.releaseAudioSession()

        SpeakLogger.logTranscription(
            event: "stop",
            model: "openai/\(modelID)",
            wordCount: result.text.split(separator: " ").count
        )
        onFinalResult?(result)

        return result
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
        captureInput.disarmDisruptionHandling()
        startup.cancel()
        cleanupCapture()
    }

    private func cleanupCapture() {
        captureInput.disarmDisruptionHandling()
        recordingLoss.cancel()
        guard isRunning || captureInput.holdsCaptureResources else { return }

        captureInput.halt()
        // Cancelled audio is thrown away, so there is nothing to drain — just
        // wait out queued chunks and drop the converter so the next session
        // builds a fresh one.
        audioProcessor.finishRun()
        transcriber?.stop()
        transcriber = nil

        audioRecorder.cancelRecording()

        isRunning = false
        activeCaptureID = nil
        captureInput.releaseAudioSession()

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
            try await captureInput.claimAudioSession()
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
        // Lost capture audio reaches the owner like a socket failure: once,
        // with the transcript so far kept as recovery text.
        conversionFailure = LivePCMConversionFailureReport { [weak self] error in
            Task { @MainActor in
                guard self?.activeCaptureID == captureID else { return }
                self?.handleError(error)
            }
        }
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
        let inputNode = captureInput.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = audioProcessor.prepareOutputFormat(
            from: nativeFormat, sampleRate: Self.targetSampleRate
        ), let conversionFailure else {
            let err = iOSTranscriptionError.audioSessionFailed(
                NSError(domain: "OpenAIRealtimeLiveTranscriber", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
            )
            self.error = err
            throw err
        }
        let client = transcriber
        let signal = firstInputSignal
        let captureID = activeCaptureID

        // The safety writer opens before the tap and the engine, so the file
        // covers the very first buffers instead of starting a beat late
        // (issue #992); a writer failure is reported, never fatal (issue #950).
        recordingLoss.startWriter(audioRecorder, format: nativeFormat)
        let run = LiveTapPCMProcessor.Run(
            recorder: audioRecorder,
            lossReport: recordingLoss.currentReport,
            outputFormat: outputFormat,
            onInput: { [weak self] in
                guard let captureID, signal.markObserved() else { return }
                Task { @MainActor [weak self] in self?.reportFirstInputBuffer(captureID) }
            },
            send: { client?.sendAudio($0) },
            onConversionFailure: conversionFailure
        )
        try captureInput.installTap { try audioProcessor.installTap(on: $0, format: nativeFormat, run: run) }
        try captureInput.startEngine()
        // Only after the engine actually returned.
        onStartupObservation?(.stage(.engineStarted))
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
