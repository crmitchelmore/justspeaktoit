#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// One factory-owned transcription session shared by foreground and hardware-trigger recording.
/// Keeping construction and lifecycle routing here prevents the two entry points from drifting.
@MainActor
final class IOSTranscriptionSession {
    enum Mode: Equatable, Sendable {
        case streaming
        case batch(retainRecording: Bool)
    }

    enum BackendKind: Equatable, Sendable {
        case batch
        case apple
        case openAI
        case shared(LiveTranscriptionProviderID)
    }

    struct Resolution: Equatable, Sendable {
        let modelID: String
        let backend: BackendKind
        let route: LiveTranscriptionRoute?

        var isBatch: Bool { backend == .batch }
        var sampleRate: Int? { route?.sampleRate }

        /// The backend this routing decision already settled, for local
        /// startup diagnostics (issue #972). `nil` for Apple, which chooses
        /// between the analyzer and the legacy recogniser at start time and
        /// labels itself once it has.
        var resolvedStartupBackend: StartupBackend? {
            switch backend {
            case .batch: return .batch
            case .openAI: return .openAIRealtime
            case .shared: return .sharedClient
            case .apple: return nil
            }
        }
    }

    var onPartialResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    /// Raised at most once per session, on the main actor, when this session's
    /// own live input tap accepts a buffer with a positive frame count. Every
    /// backend supplies it — batch included, which has no partial result — so
    /// recording presentation never waits on a signal that cannot arrive
    /// (issue #983).
    var onFirstInputBuffer: (() -> Void)?
    /// Local startup-boundary observations from whichever backend is running
    /// (issue #972). Reuses this boundary rather than adding a second one, so
    /// all five paths — Apple analyzer, the legacy Apple fallback, OpenAI
    /// Realtime, the shared client and batch — report through one seam.
    /// Measurement only: nothing here changes capture, ordering or delivery.
    var onStartupObservation: ((StartupObservation) -> Void)?

    let resolution: Resolution

    var isBatch: Bool { resolution.isBatch }

    var partialText: String {
        switch backend {
        case .batch:
            return ""
        case .apple(let transcriber):
            return transcriber.partialText
        case .openAI(let transcriber):
            return transcriber.partialText
        case .shared(let transcriber):
            return transcriber.partialText
        }
    }

    var confidence: Double? {
        guard case .apple(let transcriber) = backend else { return nil }
        return transcriber.confidence
    }

    /// The most recent microphone level, with the buffer sequence it came
    /// from, whichever backend is running.
    ///
    /// Batch is included deliberately. It publishes no partial results — see
    /// `bindCallbacks`, where `.batch` binds nothing — so an end-pointing rule
    /// written against the transcript could never fire for anyone whose
    /// transcription mode is batch, and they would turn the setting on and
    /// silently never get an auto-stop. The level is the one signal all four
    /// backends produce. The sequence is what lets a reader tell a fresh
    /// observation from the same one read twice.
    var inputLevelSample: CaptureInputLevelSample { audioRecorder.inputLevelSample }

    /// Forgets the metered level, so a new capture never inherits the previous
    /// one's last reading.
    func resetInputLevel() { audioRecorder.resetInputLevel() }

    private var audioRecorder: AudioRecordingPersistence {
        switch backend {
        case .batch(let transcriber): return transcriber.audioRecorder
        case .apple(let transcriber): return transcriber.audioRecorder
        case .openAI(let transcriber): return transcriber.audioRecorder
        case .shared(let transcriber): return transcriber.audioRecorder
        }
    }

    private enum Backend {
        case batch(IOSBatchTranscriber)
        case apple(iOSLiveTranscriber)
        case openAI(OpenAIRealtimeLiveTranscriber)
        case shared(SharedClientLiveTranscriber)
    }

    private let backend: Backend
    private let language: String?

    init(
        modelID: String,
        mode: Mode,
        language: String? = nil,
        audioSessionManager: AudioSessionManager,
        batchAPIKey: String,
        liveAPIKey: (LiveTranscriptionRoute) -> String,
        transcriptionKeywords: [String] = []
    ) throws {
        let resolution = try Self.resolve(modelID: modelID, mode: mode)
        self.resolution = resolution
        self.language = language
        backend = try Self.makeBackend(
            resolution: resolution,
            mode: mode,
            language: language,
            audioSessionManager: audioSessionManager,
            batchAPIKey: batchAPIKey,
            liveAPIKey: liveAPIKey,
            transcriptionKeywords: transcriptionKeywords
        )
        bindCallbacks()
    }

    nonisolated static func resolve(modelID: String, mode: Mode) throws -> Resolution {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .batch = mode {
            return Resolution(modelID: trimmedModelID, backend: .batch, route: nil)
        }

        guard let route = LiveTranscriptionRouting.route(for: trimmedModelID) else {
            throw LiveTranscriptionClientError.unknownModel(trimmedModelID)
        }
        let backend: BackendKind
        switch route.provider {
        case .apple:
            backend = .apple
        case .openai:
            backend = .openAI
        default:
            guard route.provider.isSupportedOnIOS else {
                throw LiveTranscriptionClientError.providerNotAvailable(route.provider)
            }
            backend = .shared(route.provider)
        }
        return Resolution(modelID: route.modelID, backend: backend, route: route)
    }

    // Keeping construction inputs together makes every recording surface use the same routing contract.
    // swiftlint:disable:next function_parameter_count
    private static func makeBackend(
        resolution: Resolution,
        mode: Mode,
        language: String?,
        audioSessionManager: AudioSessionManager,
        batchAPIKey: String,
        liveAPIKey: (LiveTranscriptionRoute) -> String,
        transcriptionKeywords: [String]
    ) throws -> Backend {
        switch resolution.backend {
        case .batch:
            let retainRecording: Bool
            if case .batch(let shouldRetain) = mode {
                retainRecording = shouldRetain
            } else {
                retainRecording = true
            }
            return .batch(
                IOSBatchTranscriber(
                    audioSessionManager: audioSessionManager,
                    model: resolution.modelID,
                    apiKey: batchAPIKey,
                    keywords: transcriptionKeywords,
                    retainRecording: retainRecording
                )
            )
        case .apple:
            let transcriber = iOSLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.modelID = resolution.modelID
            transcriber.language = language ?? Locale.current.identifier
            return .apple(transcriber)
        case .openAI:
            let route = try requiredRoute(for: resolution)
            let transcriber = OpenAIRealtimeLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: liveAPIKey(route))
            transcriber.modelID = route.apiModelName
            transcriber.language = language
            return .openAI(transcriber)
        case .shared:
            let route = try requiredRoute(for: resolution)
            return .shared(
                SharedClientLiveTranscriber(
                    route: route,
                    apiKey: liveAPIKey(route),
                    language: language,
                    keywords: [.meta, .google].contains(route.provider)
                        ? transcriptionKeywords : [],
                    audioSessionManager: audioSessionManager
                )
            )
        }
    }

    private static func requiredRoute(for resolution: Resolution) throws -> LiveTranscriptionRoute {
        guard let route = resolution.route else {
            throw LiveTranscriptionClientError.unknownModel(resolution.modelID)
        }
        return route
    }

    func start() async throws {
        try await start(preRollBuffers: [], analyzerFallbackAllowed: true)
    }

    func start(
        preRollBuffers: [AVAudioPCMBuffer],
        analyzerFallbackAllowed: Bool = true
    ) async throws {
        switch backend {
        case .batch(let transcriber):
            try await transcriber.start()
        case .apple(let transcriber):
            try await transcriber.start(
                preRollBuffers: preRollBuffers,
                analyzerFallbackAllowed: analyzerFallbackAllowed
            )
        case .openAI(let transcriber):
            try await transcriber.start()
        case .shared(let transcriber):
            try await transcriber.start()
        }
    }

    func stop() async throws -> TranscriptionResult {
        switch backend {
        case .batch(let transcriber):
            return try await transcriber.stop(language: language)
        case .apple(let transcriber):
            return await transcriber.stop()
        case .openAI(let transcriber):
            return await transcriber.stop()
        case .shared(let transcriber):
            return await transcriber.stop()
        }
    }

    func cancel() {
        switch backend {
        case .batch(let transcriber):
            transcriber.cancel()
        case .apple(let transcriber):
            transcriber.cancel()
        case .openAI(let transcriber):
            transcriber.cancel()
        case .shared(let transcriber):
            transcriber.cancel()
        }
    }

    private func bindCallbacks() {
        let partialHandler: (String, Bool) -> Void = { [weak self] text, isFinal in
            guard let self else { return }
            self.onPartialResult?(self.partialText.isEmpty ? text : self.partialText, isFinal)
        }
        let errorHandler: (Error) -> Void = { [weak self] error in
            self?.onError?(error)
        }

        let firstInputHandler: () -> Void = { [weak self] in
            self?.onFirstInputBuffer?()
        }

        let startupHandler: (StartupObservation) -> Void = { [weak self] observation in
            self?.onStartupObservation?(observation)
        }

        switch backend {
        case .batch(let transcriber):
            transcriber.onFirstInputBuffer = firstInputHandler
            transcriber.onStartupObservation = startupHandler
        case .apple(let transcriber):
            transcriber.onPartialResult = partialHandler
            transcriber.onError = errorHandler
            transcriber.onFirstInputBuffer = firstInputHandler
            // The Apple backend labels itself when it takes the analyzer or
            // the legacy branch, so a start that fails before that decision
            // reports no backend rather than the one it meant to use.
            transcriber.onStartupObservation = startupHandler
        case .openAI(let transcriber):
            transcriber.onPartialResult = partialHandler
            transcriber.onError = errorHandler
            transcriber.onFirstInputBuffer = firstInputHandler
            transcriber.onStartupObservation = startupHandler
        case .shared(let transcriber):
            transcriber.onPartialResult = partialHandler
            transcriber.onError = errorHandler
            transcriber.onFirstInputBuffer = firstInputHandler
            transcriber.onStartupObservation = startupHandler
        }

    }
}
#endif
