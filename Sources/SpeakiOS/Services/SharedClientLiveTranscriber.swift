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
    /// Raised on the main actor at most once per start, when this run's own
    /// input tap accepts a buffer with a positive frame count (issue #983).
    public var onFirstInputBuffer: (() -> Void)?
    /// Local startup-boundary observations for this start (issue #972).
    public var onStartupObservation: ((StartupObservation) -> Void)?

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
    private var cleanupTask: Task<Void, Never>?
    private var isStopping = false
    private var activeCaptureID: UUID?
    private var transcriptState: SharedClientTranscriptState?
    private var displayedRevision: UInt64 = 0
    private var displayedTranscriptRevision: UInt64 = 0
    private var reportedClientFailure = false

    // Isolates system boundaries in lifecycle tests.
    var drainCaptureWork: (() async -> Void)?
    var clientFactory: (() -> StreamingTranscriptionClient?)?
    var startCaptureAudio: (() throws -> Void)?
    var enqueueClientUpdate: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { update in
        Task { @MainActor in update() }
    }

    private let route: LiveTranscriptionRoute
    private let apiKey: String
    private let language: String?
    private let keywords: [String]

    private var client: StreamingTranscriptionClient?
    private let captureInput: LiveCaptureInput
    var configurationNotificationObject: AnyObject { captureInput.engine }
    private var startTime: Date?
    /// Finalised text so far, folded by the hosted client's declared final
    /// shape once `start()` knows which client is in use (issue #700).
    private var accumulated = TranscriptAccumulator(shape: .standaloneSegments)

    /// Persistent audio recorder — saves audio to disk alongside transcription,
    /// so a session survives the network dropping mid-stream.
    public let audioRecorder = AudioRecordingPersistence()
    let recordingLoss = RecordingLossReporting()

    /// Takes tap buffers off the real-time audio thread: persistence, the
    /// retained resampler and network sends all run on its serial queue.
    private let audioProcessor = LiveTapPCMProcessor(
        queueLabel: "com.speak.ios.sharedclient.audioProcessing", poolLabel: "ios-shared-client"
    )
    /// This run's conversion-failure owner: reported once, text kept.
    private(set) var conversionFailure: LivePCMConversionFailureReport?
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
        captureInput = LiveCaptureInput(audioSessionManager: audioSessionManager)
    }

    public func start() async throws {
        guard !isRunning, !isStopping, !startup.isStarting else { return }
        do {
            try await startup.run(
                {
                    await self.cleanupTask?.value
                    try Task.checkCancellation()
                    try await self.startCapture()
                },
                onFailure: { await self.cleanupCapture()?.value }
            )
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private func startCapture() async throws {
        recordingLoss.begin(recorder: audioRecorder)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let err = StreamingClientError.missingAPIKey(provider: route.provider.displayName)
            SpeakLogger.logError(
                err, context: "SharedClientLiveTranscriber.start", logger: SpeakLogger.transcription
            )
            self.error = err
            throw err
        }

        guard let client = makeClient() else {
            let err = LiveTranscriptionClientError.providerNotAvailable(route.provider)
            self.error = err
            throw err
        }

        SpeakLogger.logTranscription(event: "start", model: route.modelID)

        try await ensureMicrophonePermission()
        try Task.checkCancellation()
        try await configureAudioSession()
        try Task.checkCancellation()

        self.client = client
        // Fold finals by the client's declared shape: standalone segments
        // append (identical text repeats included), cumulative finals replace.
        accumulated = TranscriptAccumulator(shape: client.finalShape)
        startClient(client)

        // The startup owner's failure path drains queued capture work before
        // closing the client and releasing the audio session.
        if let startCaptureAudio {
            try startCaptureAudio()
        } else {
            try startAudioEngine()
        }
        resetState()
        observeCaptureConfiguration()
    }

    func makeClient() -> StreamingTranscriptionClient? {
        if let clientFactory { return clientFactory() }
        return LiveTranscriptionClientFactory.makeClient(
            for: route, apiKey: apiKey, language: language, keywords: keywords,
            azureEndpoint: UserDefaults.standard.string(forKey: AzureSpeechConfiguration.endpointDefaultsKey) ?? ""
        )
    }

    private func startClient(_ client: StreamingTranscriptionClient) {
        let captureID = UUID()
        let state = SharedClientTranscriptState(shape: client.finalShape)
        transcriptState = state
        activeCaptureID = captureID
        displayedRevision = 0
        displayedTranscriptRevision = 0
        reportedClientFailure = false
        firstInputSignal = FirstInputSignal()
        conversionFailure = makeConversionFailureReport(captureID: captureID, state: state)
        let enqueue = enqueueClientUpdate
        client.start(
            onTranscript: { [weak self] text, isFinal in
                guard let snapshot = state.receive(text, isFinal: isFinal) else { return }
                enqueue { [weak self] in
                    guard self?.activeCaptureID == captureID else { return }
                    self?.apply(snapshot, from: state)
                }
            },
            onError: { [weak self] error in
                guard let snapshot = state.fail(error) else { return }
                enqueue { [weak self] in
                    guard self?.activeCaptureID == captureID else { return }
                    self?.apply(snapshot, from: state)
                }
            }
        )
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
        guard isRunning, !isStopping else {
            await cleanupTask?.value
            let text = partialText.isEmpty ? accumulated.text : partialText
            return makeResult(text: text, duration: 0)
        }
        isStopping = true
        defer { isStopping = false }

        captureInput.halt()
        // Buffers handed to the queue just before the tap came off are still
        // being written and sent; let them land before the client is finalised
        // and the recorder is closed.
        await audioProcessor.drainPendingWork()
        guard isRunning else {
            await cleanupTask?.value
            return makeResult(text: partialText, duration: 0)
        }
        // The retained resampler is still holding the frames whose filter
        // window has not closed. Flush them down the same send path the live
        // chunks use, before the client is finalised, or the tail of a short
        // utterance is dropped (issue #872).
        await drainConverterTail()
        audioProcessor.finishRun()
        guard isRunning else {
            await cleanupTask?.value
            return makeResult(text: partialText, duration: 0)
        }
        await finishClient()
        guard isRunning else {
            await cleanupTask?.value
            return makeResult(text: partialText, duration: 0)
        }
        activeCaptureID = nil
        recordingLoss.finish(recorder: audioRecorder, run: lossRun)
        isRunning = false
        captureInput.releaseAudioSession()

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
        captureInput.disarmDisruptionHandling()
        startup.cancel()
        _ = cleanupCapture()
    }

    func awaitCancellationSettled() async {
        await cleanupTask?.value
    }

    private func cleanupCapture() -> Task<Void, Never>? {
        captureInput.disarmDisruptionHandling()
        recordingLoss.cancel()
        if let cleanupTask { return cleanupTask }
        guard isRunning || captureInput.holdsCaptureResources else { return nil }
        captureInput.halt()
        if let state = transcriptState { apply(state.cancel(), from: state, notify: false) }
        activeCaptureID = nil
        isRunning = false
        let task = Task { @MainActor in
            if let drainCaptureWork {
                await drainCaptureWork()
            } else {
                await audioProcessor.drainPendingWork()
            }
            finishCaptureCleanup()
            cleanupTask = nil
        }
        cleanupTask = task
        return task
    }

    private func finishCaptureCleanup() {
        client?.cancel()
        client = nil
        // Cancelled audio is thrown away, so there is nothing to drain — just
        // drop the converter so the next session builds a fresh one.
        audioProcessor.finishRun()
        // Cancel persistent recording (keeps the partial file).
        audioRecorder.cancelRecording()
        captureInput.releaseAudioSession()
    }

}

extension SharedClientLiveTranscriber {
    /// Captured from the actual active client, with time for capture drain and
    /// terminal UI delivery. Providers without a declared budget retain 10s.
    var stopCompletionTimeout: TimeInterval {
        guard let budget = (client as? FinalizingStreamingTranscriptionClient)?.finalisationBudget,
              budget.isFinite, budget > 0 else { return 10 }
        return max(10, budget + 1)
    }

    // MARK: - Private

    /// Closes the client, giving providers that can still deliver words a
    /// bounded grace period first.
    ///
    /// Clients that flush buffered audio always drain, because unseen words
    /// can still arrive. A client declaring a wait-only finish can close as
    /// soon as its last interim and all sent audio have been accounted for.
    private func finishClient() async {
        guard let finishingClient = client, let state = transcriptState else { return }
        let captureID = activeCaptureID
        defer { if client === finishingClient { client = nil } }
        let beforeFinish = state.snapshot
        var whole: String?
        if let finalizingClient = finishingClient as? FinalizingStreamingTranscriptionClient,
           StreamingFinalisationPolicy.shouldAwaitFinalisation(
               finishFlushesBufferedAudio: finalizingClient.finishFlushesBufferedAudio,
               hasUnfinalisedTranscript: beforeFinish.text != beforeFinish.confirmedText,
               hasUnansweredAudio: unansweredAudio.isSet
           ) {
            whole = await finalizingClient.finishAndWait()
        } else {
            finishingClient.stop()
        }
        if Task.isCancelled { finishingClient.cancel() }
        guard activeCaptureID == captureID else { return }
        // Error callbacks update state synchronously. Deliver the terminal
        // snapshot before retiring the run, even when their UI tasks are pending.
        apply(state.finish(whole: whole, cancelled: Task.isCancelled), from: state)
    }

    private func apply(
        _ snapshot: SharedClientTranscriptState.Snapshot,
        from state: SharedClientTranscriptState,
        notify: Bool = true
    ) {
        guard transcriptState === state, snapshot.revision >= displayedRevision else { return }
        displayedRevision = snapshot.revision
        if finalText != snapshot.confirmedText {
            accumulated.replace(with: snapshot.confirmedText)
            finalText = snapshot.confirmedText
        }
        partialText = snapshot.text
        if let failure = snapshot.error { error = failure }
        if snapshot.transcriptRevision > displayedTranscriptRevision {
            displayedTranscriptRevision = snapshot.transcriptRevision
            unansweredAudio.clear()
            if notify { onPartialResult?(snapshot.text, snapshot.isFinal) }
        }
        // User callbacks can synchronously cancel this run. Never deliver a
        // second notification into the cancellation or a replacement session.
        guard notify, activeCaptureID != nil, transcriptState === state,
              let failure = snapshot.error, !reportedClientFailure else { return }
        reportedClientFailure = true
        onError?(failure)
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
            try Task.checkCancellation()
            if !granted {
                let err = iOSTranscriptionError.permissionDenied(.microphone)
                self.error = err
                throw err
            }
        }
    }

    private func configureAudioSession() async throws {
        do {
            try await captureInput.claimAudioSession()
            onStartupObservation?(.stage(.audioSessionConfigured))
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
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

}

// MARK: - Audio capture

private extension SharedClientLiveTranscriber {
    func startAudioEngine() throws {
        let inputNode = captureInput.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = audioProcessor.prepareOutputFormat(
            from: nativeFormat, sampleRate: Double(route.sampleRate)
        ), let conversionFailure else {
            let err = iOSTranscriptionError.audioSessionFailed(
                NSError(domain: "SharedClientLiveTranscriber", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to build audio converter"])
            )
            self.error = err
            throw err
        }
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
            send: Self.sender(to: client, recording: unansweredAudio) ?? { _ in },
            onConversionFailure: conversionFailure
        )
        try captureInput.installTap { try audioProcessor.installTap(on: $0, format: nativeFormat, run: run) }
        try captureInput.startEngine()
        // Only after the engine actually returned.
        onStartupObservation?(.stage(.engineStarted))
    }

    /// Lost capture audio fails this run like a provider error: reported once,
    /// with the text received so far kept for recovery.
    func makeConversionFailureReport(
        captureID: UUID, state: SharedClientTranscriptState
    ) -> LivePCMConversionFailureReport {
        let enqueue = enqueueClientUpdate
        return LivePCMConversionFailureReport { [weak self] error in
            guard let snapshot = state.fail(error) else { return }
            enqueue { [weak self] in
                guard let self, self.activeCaptureID == captureID else { return }
                self.apply(snapshot, from: state)
            }
        }
    }

    /// Every chunk handed to the client, the converter tail included, is
    /// audio no response has accounted for yet (issue #641).
    nonisolated static func sender(
        to client: StreamingTranscriptionClient?, recording unansweredAudio: UnansweredAudioSignal
    ) -> (@Sendable (Data) -> Void)? {
        guard let client else { return nil }
        return { data in
            unansweredAudio.record()
            client.sendAudio(data)
        }
    }

    /// Flushes the retained resampler's trailing frames down the same send path
    /// the live chunks use, before the client is finalised (issue #872).
    func drainConverterTail() async {
        await audioProcessor.drainTail(send: Self.sender(to: client, recording: unansweredAudio))
    }
}

#endif
