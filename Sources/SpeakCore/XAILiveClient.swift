import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Grok Voice with manual turns and no `response.create`: only input captions
/// are consumed. Desktop exposure still requires transcription-only qualification.
public final class XAILiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .cumulativeTranscript
    public let finishFlushesBufferedAudio = true
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    static let finishBudgetSeconds: TimeInterval = 5
    private let lifecycle: StreamingProviderSession
    var preroll: StreamingAudioPreroll { lifecycle.preroll }
    private let outcomeLock = NSLock()
    private var outcomeGeneration = 0
    private var storedFinishOutcome: FinishOutcome?
    var lastFinishOutcome: FinishOutcome? { outcomeLock.withLock { self.storedFinishOutcome } }

    public convenience init(
        apiKey: String, model: String = XAIVoiceModels.thinkFast2APIName,
        language: String? = nil, sampleRate: Int = 24_000, session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) }
        )
    }

    public init(
        apiKey: String, model: String = XAIVoiceModels.thinkFast2APIName,
        language: String? = nil, sampleRate: Int = 24_000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        var configuration = StreamingProviderSession.Configuration(
            provider: "xAI Grok Voice", sampleRate: sampleRate, shape: .cumulativeTranscript,
            finishBudget: Self.finishBudgetSeconds,
            request: {
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw StreamingClientError.missingAPIKey(provider: "xAI") }
                guard let url = Self.webSocketURL(model: model) else { throw StreamingClientError.invalidURL }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                return request
            },
            setup: {
                guard let text = Self.sessionUpdateJSON(sampleRate: sampleRate, language: language) else {
                    throw XAILiveError.encodingFailed
                }
                return .text(text)
            },
            audio: { data, _ in
                let object = ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]
                let encoded = try JSONSerialization.data(withJSONObject: object)
                guard let text = String(data: encoded, encoding: .utf8) else { throw XAILiveError.encodingFailed }
                return .text(text)
            },
            end: .text(#"{"type":"input_audio_buffer.commit"}"#),
            decode: Self.events
        )
        configuration.finalCompletes = true
        configuration.cumulativeInterims = true
        configuration.transportError = { error in
            let detail = error.localizedDescription.lowercased()
            if detail.contains("401") || detail.contains("403")
                || detail.contains("unauthorized") || detail.contains("forbidden") {
                return StreamingClientError.invalidAPIKey(provider: "xAI")
            }
            return error
        }
        lifecycle = StreamingProviderSession(
            configuration: configuration, makeConnection: makeConnection, schedule: schedule
        )
    }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        outcomeLock.withLock {
            self.outcomeGeneration += 1
            self.storedFinishOutcome = nil
        }
        lifecycle.start(onTranscript: onTranscript, onError: onError)
    }
    public func sendAudio(_ audioData: Data) { lifecycle.sendAudio(audioData) }
    public func stop() { lifecycle.stop() }
    public func finishAndWait() async -> String? {
        let generation = outcomeLock.withLock { self.outcomeGeneration }
        let result = await lifecycle.finishAndWaitResult()
        let outcome: FinishOutcome
        if result.failed {
            outcome = .transportFailure
        } else if result.hasFinal {
            outcome = .confirmedFinal
        } else {
            outcome = .bestAvailable
        }
        outcomeLock.withLock {
            if generation == self.outcomeGeneration { self.storedFinishOutcome = outcome }
        }
        return result.transcript
    }
    func ingest(_ text: String) { lifecycle.ingest(text) }

    private static func events(_ text: String) -> [StreamingProviderSession.Event] {
        if let event = Self.transcriptEvent(from: text) {
            return [event.isFinal ? .final(event.text) : .interim(event.text)]
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        if object["type"] as? String == "session.updated" { return [.ready] }
        if object["type"] as? String == "error" {
            let error = object["error"] as? [String: Any]
            return [.failure(XAILiveError.server(error?["message"] as? String ?? "Unknown xAI realtime error"))]
        }
        return []
    }
}

public enum XAILiveError: LocalizedError {
    case encodingFailed
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Could not encode the xAI realtime transcription request."
        case .server(let message): return "xAI realtime transcription failed: \(message)"
        }
    }
}
