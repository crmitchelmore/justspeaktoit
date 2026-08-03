#if os(iOS)
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
        case deepgram
        case elevenLabs
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
        case .deepgram(let transcriber):
            return transcriber.partialText
        case .elevenLabs(let transcriber):
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
        case deepgram(DeepgramLiveTranscriber)
        case elevenLabs(ElevenLabsLiveTranscriber)
        case openAI(OpenAIRealtimeLiveTranscriber)
        case shared(SharedClientLiveTranscriber)
    }

    private let backend: Backend

    init(
        modelID: String,
        mode: Mode,
        audioSessionManager: AudioSessionManager,
        batchAPIKey: String,
        liveAPIKey: (LiveTranscriptionRoute) -> String
    ) throws {
        let resolution = try Self.resolve(modelID: modelID, mode: mode)
        self.resolution = resolution
        backend = try Self.makeBackend(
            resolution: resolution,
            mode: mode,
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
        case .deepgram:
            backend = .deepgram
        case .elevenlabs:
            backend = .elevenLabs
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

    private static func makeBackend(
        resolution: Resolution,
        mode: Mode,
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
            return .apple(transcriber)
        case .deepgram:
            let route = try requiredRoute(for: resolution)
            let transcriber = DeepgramLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: liveAPIKey(route))
            transcriber.model = route.apiModelName
            return .deepgram(transcriber)
        case .elevenLabs:
            let route = try requiredRoute(for: resolution)
            let transcriber = ElevenLabsLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: liveAPIKey(route))
            transcriber.modelID = route.apiModelName
            return .elevenLabs(transcriber)
        case .openAI:
            let route = try requiredRoute(for: resolution)
            let transcriber = OpenAIRealtimeLiveTranscriber(audioSessionManager: audioSessionManager)
            transcriber.configure(apiKey: liveAPIKey(route))
            transcriber.modelID = route.apiModelName
            return .openAI(transcriber)
        case .shared:
            let route = try requiredRoute(for: resolution)
            return .shared(
                SharedClientLiveTranscriber(
                    route: route,
                    apiKey: liveAPIKey(route),
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
        switch backend {
        case .batch(let transcriber):
            try await transcriber.start()
        case .apple(let transcriber):
            try await transcriber.start()
        case .deepgram(let transcriber):
            try await transcriber.start()
        case .elevenLabs(let transcriber):
            try await transcriber.start()
        case .openAI(let transcriber):
            try await transcriber.start()
        case .shared(let transcriber):
            try await transcriber.start()
        }
    }

    func stop(language: String?) async throws -> TranscriptionResult {
        switch backend {
        case .batch(let transcriber):
            return try await transcriber.stop(language: language)
        case .apple(let transcriber):
            return await transcriber.stop()
        case .deepgram(let transcriber):
            return await transcriber.stop()
        case .elevenLabs(let transcriber):
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
        case .deepgram(let transcriber):
            transcriber.cancel()
        case .elevenLabs(let transcriber):
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
        case .deepgram(let transcriber):
            transcriber.onPartialResult = partialHandler
            transcriber.onError = errorHandler
        case .elevenLabs(let transcriber):
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
