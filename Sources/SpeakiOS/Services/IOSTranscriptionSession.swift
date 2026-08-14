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
    }

    var onPartialResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

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
        liveAPIKey: (LiveTranscriptionRoute) -> String
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
            liveAPIKey: liveAPIKey
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
        liveAPIKey: (LiveTranscriptionRoute) -> String
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

        switch backend {
        case .batch:
            break
        case .apple(let transcriber):
            transcriber.onPartialResult = partialHandler
            transcriber.onError = errorHandler
        case .openAI(let transcriber):
            transcriber.onPartialResult = partialHandler
            transcriber.onError = errorHandler
        case .shared(let transcriber):
            transcriber.onPartialResult = partialHandler
            transcriber.onError = errorHandler
        }
    }
}
#endif
