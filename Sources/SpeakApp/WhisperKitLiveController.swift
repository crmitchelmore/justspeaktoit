import Foundation
import SpeakCore

/// Live local streaming via WhisperKit's `AudioStreamTranscriber`.
///
/// Lifecycle is the run-identity state machine shared with
/// `FluidAudioParakeetLiveController`: every start mints a run ID before any
/// awaited work, every later step and callback requires that ID to still be
/// current, and stop retires the ID only after owned cleanup. A stop during
/// cold model preparation therefore never lets the microphone start, late
/// events from a retired run cannot touch a replacement, and each run produces
/// exactly one terminal delegate outcome (issue #713).
///
/// Stop also owns finalisation: WhisperKit's streaming loop only decodes once
/// more than a second of new audio exists, so the controller decodes the
/// remaining tail itself before reporting the recording finished.
@MainActor
final class WhisperKitLiveController: LiveTranscriptionController {
    typealias StreamProvider = @MainActor (
        _ request: WhisperKitStreamRequest,
        _ onEvent: @escaping WhisperKitStreamEventHandler
    ) async throws -> any WhisperKitLiveStreaming

    weak var delegate: LiveTranscriptionSessionDelegate?

    private enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopping
    }

    var isRunning: Bool { phase == .running }

    private let permissionsManager: PermissionsManager
    private let audioDeviceManager: AudioInputDeviceManager
    private let modelManager: LocalModelManager
    private let streamProvider: StreamProvider?
    private let startupTimeout: Duration
    private let finalisationTimeout: Duration
    private let logger = SpeakLogger.logger(category: "WhisperKitLive")

    private var phase: Phase = .idle
    private var runID: UUID?
    private var startTask: Task<Void, any Error>?
    private var finishTask: Task<Void, Never>?
    private var stream: (any WhisperKitLiveStreaming)?
    private var streamTask: Task<Void, Never>?
    private var startupContinuation: CheckedContinuation<Void, any Error>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var activeInputSession: AudioInputDeviceManager.SessionContext?
    private var currentLanguage: String?
    private var currentModel = WhisperKitStreamingModel.prefix + "tiny"
    private var latestState = WhisperKitTranscriptState()
    private var latestText = ""
    private var startedAt: Date?
    private var streamFailure: (any Error)?
    private var didDeliverFailure = false

    init(
        permissionsManager: PermissionsManager,
        audioDeviceManager: AudioInputDeviceManager,
        modelManager: LocalModelManager,
        streamProvider: StreamProvider? = nil,
        startupTimeout: Duration = .seconds(10),
        finalisationTimeout: Duration = .seconds(15)
    ) {
        self.permissionsManager = permissionsManager
        self.audioDeviceManager = audioDeviceManager
        self.modelManager = modelManager
        self.streamProvider = streamProvider
        self.startupTimeout = startupTimeout
        self.finalisationTimeout = finalisationTimeout
    }

    func configure(language: String?, model: String) {
        currentLanguage = language
        currentModel = model
    }

    func start() async throws {
        guard phase == .idle else {
            throw TranscriptionManagerError.liveSessionAlreadyRunning
        }
        let run = UUID()
        runID = run
        phase = .starting
        latestState = WhisperKitTranscriptState()
        latestText = ""
        streamFailure = nil
        didDeliverFailure = false

        // Startup runs in an owned task so a concurrent stop can cancel it and
        // await its unwinding before tearing down whatever it already acquired.
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performStart(run: run)
        }
        startTask = task
        do {
            try await task.value
            if startTask == task { startTask = nil }
        } catch {
            if startTask == task { startTask = nil }
            // When phase is `.stopping` a concurrent stop owns the teardown; it
            // is already awaiting this task and cleans up once we unwind.
            if runID == run, phase == .starting {
                await teardownRunResources()
                retire(run)
            }
            throw error
        }
    }

    func stop() async {
        switch phase {
        case .idle:
            return
        case .stopping:
            await finishTask?.value
        case .starting:
            guard let run = runID else { return }
            await finish { await self.abortStart(run) }
        case .running:
            guard let run = runID else { return }
            await finish { await self.stopRunning(run, failure: nil) }
        }
    }

    // MARK: - Startup

    private func performStart(run: UUID) async throws {
        guard await permissionsManager.ensureGranted(.microphone).isGranted else {
            throw TranscriptionManagerError.microphonePermissionMissing
        }
        try ensureActive(run)
        guard let batchModelID = WhisperKitStreamingModel.batchModelID(from: currentModel) else {
            throw TranscriptionManagerError.invalidLocalStreamingSource(currentModel)
        }

        // Each resource is published to `self` immediately upon acquisition so
        // a stop that cancelled this task can tear everything down after
        // awaiting our unwinding.
        let request = WhisperKitStreamRequest(
            batchModelID: batchModelID,
            language: Self.languageCode(currentLanguage)
        )
        let stream = try await makeStream(request: request, run: run)
        self.stream = stream
        try ensureActive(run)

        activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
        try ensureActive(run)
        startedAt = Date()

        try await awaitFirstAudio(from: stream, run: run)
        try ensureActive(run)
        // The stream can end between its first audio and this resumption;
        // that is a failed start, not a running session with a dead stream.
        if let streamFailure {
            throw streamFailure
        }
        phase = .running
    }

    private func makeStream(request: WhisperKitStreamRequest, run: UUID) async throws -> any WhisperKitLiveStreaming {
        let onEvent: WhisperKitStreamEventHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, run: run)
            }
        }
        if let streamProvider {
            return try await streamProvider(request, onEvent)
        }
        let pipeline = try await modelManager.makeReadyPipeline(modelID: request.batchModelID)
        return try WhisperKitLiveStream(pipeline: pipeline, request: request, onEvent: onEvent)
    }

    /// Runs the stream and suspends until its first audio arrives, a timeout
    /// elapses, the stream ends, or a stop resolves the wait.
    private func awaitFirstAudio(from stream: any WhisperKitLiveStreaming, run: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            startupContinuation = continuation
            streamTask = Task { @MainActor [weak self] in
                do {
                    try await stream.startStream()
                    await self?.streamEnded(error: nil, run: run)
                } catch {
                    await self?.streamEnded(error: error, run: run)
                }
            }
            startupTimeoutTask = Task { @MainActor [weak self, startupTimeout] in
                guard (try? await Task.sleep(for: startupTimeout)) != nil else { return }
                self?.resolveStartup(
                    .failure(TranscriptionManagerError.localLiveStreamingStartupTimedOut),
                    run: run
                )
            }
        }
    }

    private func resolveStartup(_ result: Result<Void, any Error>, run: UUID) {
        guard runID == run, let continuation = startupContinuation else { return }
        startupContinuation = nil
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        continuation.resume(with: result)
    }

    /// Startup barrier: throws unless `run` is still the live starting run.
    private func ensureActive(_ run: UUID) throws {
        try Task.checkCancellation()
        guard runID == run, phase == .starting else {
            throw CancellationError()
        }
    }

    private static func languageCode(_ language: String?) -> String? {
        language?
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first
            .map { $0.lowercased() }
    }
}

// MARK: - Stop

extension WhisperKitLiveController {
    private func finish(_ body: @escaping @MainActor () async -> Void) async {
        phase = .stopping
        let task = Task { @MainActor in await body() }
        finishTask = task
        await task.value
        if finishTask == task { finishTask = nil }
    }

    private func abortStart(_ run: UUID) async {
        let task = startTask
        startTask = nil
        task?.cancel()
        resolveStartup(.failure(TranscriptionManagerError.liveSessionNotRunning), run: run)
        _ = try? await task?.value
        await teardownRunResources()
        retire(run)
    }

    private func stopRunning(_ run: UUID, failure: (any Error)?) async {
        let stream = self.stream
        await stream?.stopStream()
        // The streaming loop exits after its in-flight decode; the state
        // changes it publishes on the way out still belong to this run.
        let drain = streamTask
        streamTask = nil
        await drain?.value

        let failure = failure ?? streamFailure
        var finalText = latestText
        if failure == nil, let stream {
            finalText = await finalise(with: stream)
        }
        self.stream = nil
        await endActiveInputSession()

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        retire(run)

        if let failure {
            deliverFailureIfNeeded(failure)
            return
        }
        delegate?.liveTranscriber(
            self,
            didFinishWith: TranscriptionResult(
                text: finalText,
                segments: [],
                confidence: nil,
                duration: duration,
                modelIdentifier: currentModel,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        )
    }

    /// Decodes the audio after the last confirmed segment so trailing speech
    /// the streaming loop never reached (including recordings shorter than
    /// its one-second minimum) makes it into the result.
    private func finalise(with stream: any WhisperKitLiveStreaming) async -> String {
        let state = latestState
        let tailStart = WhisperKitTranscriptProjection.tailStart(for: state)
        let outcome = await BoundedOperation.run(timeout: finalisationTimeout) {
            try await stream.decodeTail(after: tailStart)
        }
        switch outcome {
        case .success(let tailText):
            return WhisperKitTranscriptProjection.finalText(
                for: state,
                tailText: tailText,
                displayedText: latestText
            )
        case .failure(let error):
            logger.warning(
                "WhisperKit tail decode failed; keeping streamed text: \(error.localizedDescription, privacy: .public)")
            return latestText
        case nil:
            logger.warning("WhisperKit tail decode timed out; keeping streamed text")
            return latestText
        }
    }

    /// Cleanup for runs that never reached `.running`. Publishes no delegate
    /// outcome: the start path throws to its caller instead.
    private func teardownRunResources() async {
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        if let stream {
            self.stream = nil
            await stream.stopStream()
        }
        let drain = streamTask
        streamTask = nil
        await drain?.value
        await endActiveInputSession()
        startedAt = nil
    }

    private func retire(_ run: UUID) {
        guard runID == run else { return }
        runID = nil
        phase = .idle
    }

    private func endActiveInputSession() async {
        guard let session = activeInputSession else { return }
        activeInputSession = nil
        await audioDeviceManager.endUsingPreferredInput(session: session)
    }

    private func deliverFailureIfNeeded(_ error: any Error) {
        guard !didDeliverFailure else { return }
        didDeliverFailure = true
        delegate?.liveTranscriber(self, didFail: error)
    }
}

// MARK: - Stream callbacks

extension WhisperKitLiveController {
    private func handle(_ event: WhisperKitStreamEvent, run: UUID) {
        guard runID == run else { return }
        switch event {
        case .audioArrived:
            resolveStartup(.success(()), run: run)
        case .transcript(let state):
            latestState = state
            let text = WhisperKitTranscriptProjection.displayText(for: state)
            guard text != latestText else { return }
            latestText = text
            delegate?.liveTranscriber(self, didUpdatePartial: text)
        }
    }

    /// Called from the stream task when `startStream()` returns, so it must
    /// never await that task.
    private func streamEnded(error: (any Error)?, run: UUID) async {
        guard runID == run else { return }
        streamTask = nil
        if startupContinuation != nil {
            resolveStartup(.failure(error ?? TranscriptionManagerError.liveSessionNotRunning), run: run)
            return
        }
        switch phase {
        case .running:
            // WhisperKit's loop also returns normally after an internal decode
            // error, so any end while running is a failure of the run.
            let failure = error ?? TranscriptionManagerError.liveSessionNotRunning
            streamFailure = failure
            await finish { await self.stopRunning(run, failure: failure) }
        case .starting:
            streamFailure = error ?? TranscriptionManagerError.liveSessionNotRunning
        case .stopping:
            if let error { streamFailure = error }
        case .idle:
            break
        }
    }
}
