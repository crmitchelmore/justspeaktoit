import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Meta's dedicated realtime ASR protocol over a host-owned native transport.
public final class MetaMuseLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    static let finishBudget: TimeInterval = 5
    private let lifecycle: StreamingProviderSession
    var preroll: StreamingAudioPreroll { lifecycle.preroll }
    var isSessionConfigured: Bool { lifecycle.isReady }

    public convenience init(
        apiKey: String, model: String = MetaMuseVoiceTranscribe.modelID,
        language: String? = nil, keywords: [String] = [], sampleRate: Int = 24_000,
        session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, keywords: keywords, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        apiKey: String, model: String = MetaMuseVoiceTranscribe.modelID,
        language: String? = nil, keywords: [String] = [], sampleRate: Int = 24_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var configuration = StreamingProviderSession.Configuration(
            provider: "Meta", sampleRate: sampleRate, shape: .standaloneSegments, finishBudget: Self.finishBudget,
            request: {
                guard !key.isEmpty else { throw MetaMuseError.missingAPIKey }
                _ = try Self.audioEncoding(forSampleRate: sampleRate)
                guard let url = Self.webSocketURL() else { throw MetaMuseError.invalidResponse }
                return URLRequest(url: url)
            },
            setup: {
                let data = try Self.handshakeData(
                    apiKey: key, model: model, sampleRate: sampleRate, language: language, keywords: keywords
                )
                guard let text = String(data: data, encoding: .utf8) else { throw MetaMuseError.invalidResponse }
                return .text(text)
            },
            audio: { audio, _ in .binary(audio) },
            end: .text(#"{"type":"endStream"}"#),
            decode: Self.events
        )
        configuration.finalCompletes = true
        configuration.maximumReconnects = 1
        configuration.retryBeforeReady = { error in
            let code = (error as? any StreamingWebSocketCloseReporting)?.webSocketCloseCode
            return Self.shouldReconnect(didHandshake: false, attempt: 0, closeCode: code, isEnding: false)
        }
        configuration.transportError = { error in
            let code = (error as? any StreamingWebSocketCloseReporting)?.webSocketCloseCode ?? 0
            return Self.error(closeCode: code, reason: nil, fallback: error)
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
    func awaitTrailingFinal(
        budget: TimeInterval = MetaMuseLiveClient.finishBudget, whenArmed: () -> Void = {}
    ) async -> String? {
        await lifecycle.awaitFinal(budget: budget, whenArmed: whenArmed)
    }

    private static func events(_ text: String) -> [StreamingProviderSession.Event] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        if object["type"] == nil, object["sessionId"] is String { return [.ready] }
        guard let event = MetaMuseServerEvent(object: object) else { return [] }
        switch event {
        case .transcript(let text): return [.interim(text)]
        case .speechComplete(let turnID, let text): return [.final(text, id: String(turnID))]
        case .error(let message): return [.failure(Self.error(fromServerMessage: message))]
        case .lifecycle: return []
        }
    }
}
