import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gemini Live transcription framing over an injected, native WebSocket.
/// Never requests a model response or consumes assistant output transcription.
public final class GeminiLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    static let finishBudgetSeconds: TimeInterval = 4

    let customVocabulary: [String]
    private let lifecycle: StreamingProviderSession
    var preroll: StreamingAudioPreroll { lifecycle.preroll }

    public convenience init(
        apiKey: String,
        model: String = GeminiTranscribeModels.liveAPIName,
        language: String? = nil,
        customVocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim,
        sampleRate: Int = 16_000,
        session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, customVocabulary: customVocabulary,
            mode: mode, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        apiKey: String,
        model: String = GeminiTranscribeModels.liveAPIName,
        language: String? = nil,
        customVocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim,
        sampleRate: Int = 16_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.customVocabulary = customVocabulary
        var configuration = StreamingProviderSession.Configuration(
            provider: GeminiTranscribeModels.providerDisplayName, sampleRate: sampleRate,
            shape: .standaloneSegments, finishBudget: Self.finishBudgetSeconds,
            request: {
                guard let url = Self.webSocketURL(apiKey: apiKey) else {
                    throw StreamingClientError.missingAPIKey(provider: GeminiTranscribeModels.providerDisplayName)
                }
                return URLRequest(url: url)
            },
            setup: {
                guard let text = Self.setupMessageJSON(
                    model: model, language: language, customVocabulary: customVocabulary, mode: mode
                ) else { throw GeminiLiveError.encodingFailed }
                return .text(text)
            },
            audio: { audio, _ in
                guard let text = Self.audioChunkJSON(audio, sampleRate: sampleRate) else {
                    throw GeminiLiveError.encodingFailed
                }
                return .text(text)
            },
            end: .text(Self.audioStreamEndJSON()),
            decode: Self.events
        )
        configuration.finalCompletes = true
        configuration.maximumReconnects = 3
        configuration.transportError = { error in
            let native = error as NSError
            let detail = native.localizedDescription.lowercased()
            if [401, 403].contains(native.code) || detail.contains("401") || detail.contains("403")
                || detail.contains("unauthorized") || detail.contains("forbidden") {
                return StreamingClientError.invalidAPIKey(provider: GeminiTranscribeModels.providerDisplayName)
            }
            if native.code == 429 || detail.contains("429") {
                return GeminiLiveError.rateLimited(native.localizedDescription)
            }
            return error
        }
        lifecycle = StreamingProviderSession(
            configuration: configuration, makeConnection: makeConnection, schedule: schedule
        )
    }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lifecycle.start(onTranscript: onTranscript, onError: onError)
    }
    public func sendAudio(_ audioData: Data) { lifecycle.sendAudio(audioData) }
    public func stop() { lifecycle.stop() }
    public func finishAndWait() async -> String? { await lifecycle.finishAndWait() }

    func beginSession(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lifecycle.beginSession(onTranscript: onTranscript, onError: onError)
    }
    func ingest(_ text: String) { lifecycle.ingest(text) }
    func waitForTrailingFinal(deadline: Date, whenArmed: () -> Void = {}) async -> String? {
        await lifecycle.awaitFinal(budget: max(0, deadline.timeIntervalSinceNow), whenArmed: whenArmed)
    }

    private static func events(_ text: String) -> [StreamingProviderSession.Event] {
        var events: [StreamingProviderSession.Event] = []
        if let transcript = Self.transcriptEvent(from: text) {
            events.append(transcript.isFinal ? .final(transcript.text) : .interim(transcript.text))
        }
        if let signal = Self.serverSignal(from: text) {
            switch signal {
            case .setupComplete: events.append(.ready)
            case .turnComplete: events.append(.complete)
            case .goAway: events.append(.reconnect)
            case .failure(let code, let status, let message):
                events.append(.failure(Self.mapServerFailure(code: code, status: status, message: message)))
            }
        }
        return events
    }
}
