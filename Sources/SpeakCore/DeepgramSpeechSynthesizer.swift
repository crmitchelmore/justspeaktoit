import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Executes Deepgram voice-output requests: pronunciation, limits and one
/// bounded, cancellable HTTP exchange.
///
/// The request is built by `DeepgramTTSAPI.speakRequest`, the same shape the
/// Apple clients send, and asks for lossless linear16 in a WAV container at
/// Deepgram's native 24 kHz, as the macOS client's WAV path does. The body
/// streams through `OpenRouterBoundedResponseTransport`: a declared or
/// received size above the limit stops the transfer, a wall-clock deadline
/// bounds the exchange, redirects and caching are refused, and task
/// cancellation cancels the transfer. Error statuses are classified from
/// headers alone, because provider bodies can echo request text.
struct DeepgramSpeechSynthesizer: Sendable {
    /// The text to send and the voice that speaks it.
    struct Utterance: Equatable, Sendable {
        let text: String
        let voice: DeepgramSpeechCatalog.Voice

        var characterCount: Int { text.unicodeScalars.count }
    }

    static let sampleRate = 24_000
    /// Ten minutes of 24 kHz mono PCM16 plus its header: several times the
    /// longest speech 2,000 characters produce.
    static let defaultResponseLimit = 44 + sampleRate * 2 * 600
    static let defaultDeadline: Duration = .seconds(120)
    /// Bounds pronunciation work on oversized input before the provider limit
    /// can be measured on the rendered text.
    static let maximumSourceCharacters = DeepgramSpeechRequest.maximumCharacters * 10

    private let session: URLSession
    private let responseLimit: Int
    private let deadline: Duration
    private let engine: OpenRouterBoundedResponseTransport.Engine
    private let renderer: PronunciationRenderer

    init(
        session: URLSession = .shared,
        responseLimit: Int = DeepgramSpeechSynthesizer.defaultResponseLimit,
        deadline: Duration = DeepgramSpeechSynthesizer.defaultDeadline,
        engine: OpenRouterBoundedResponseTransport.Engine = .platformDefault,
        renderer: PronunciationRenderer = PronunciationRenderer()
    ) {
        precondition(responseLimit > 44 && deadline > .zero, "Deepgram speech needs a positive response bound")
        self.session = session
        self.responseLimit = responseLimit
        self.deadline = deadline
        self.engine = engine
        self.renderer = renderer
    }

    /// The pronounced, trimmed text to send, or `nil` when there is nothing to
    /// speak. Pure: no credential, network or file is touched. Pronunciation
    /// applies to the text as supplied, exactly as the dictionary manager does.
    func utterance(for request: DeepgramSpeechRequest) throws -> Utterance? {
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard !request.text.unicodeScalars.allSatisfy(whitespace.contains) else { return nil }
        let sourceCount = request.text.unicodeScalars.count
        guard sourceCount <= Self.maximumSourceCharacters else {
            throw DeepgramSpeechError.textTooLong(
                characterCount: sourceCount, limit: DeepgramSpeechRequest.maximumCharacters
            )
        }
        let text = renderer.applyReplacements(to: request.text, entries: request.pronunciation)
            .trimmingCharacters(in: whitespace)
        guard !text.isEmpty else { return nil }
        let utterance = Utterance(text: text, voice: request.voice)
        guard utterance.characterCount <= DeepgramSpeechRequest.maximumCharacters else {
            throw DeepgramSpeechError.textTooLong(
                characterCount: utterance.characterCount, limit: DeepgramSpeechRequest.maximumCharacters
            )
        }
        return utterance
    }

    func synthesize(_ utterance: Utterance, apiKey: String) async throws -> DeepgramSpeechAudio {
        try Task.checkCancellation()
        let request: URLRequest
        do {
            request = try DeepgramTTSAPI.speakRequest(
                text: utterance.text, apiKey: apiKey, queryItems: Self.queryItems(for: utterance.voice)
            )
        } catch {
            throw DeepgramSpeechError.invalidResponse
        }
        let body: Data
        do {
            body = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: responseLimit, deadline: deadline, engine: engine
            ) { http in
                switch DeepgramTTSAPI.failure(statusCode: http.statusCode, message: "") {
                case .unauthorized(let statusCode, _): throw DeepgramSpeechError.unauthorized(statusCode: statusCode)
                case .httpError(let statusCode, _): throw DeepgramSpeechError.httpStatus(statusCode)
                case .invalidURL, .invalidResponse: throw DeepgramSpeechError.invalidResponse
                case nil: break
                }
            }.body
        } catch {
            throw Self.speechError(from: error)
        }
        try Task.checkCancellation()
        return try DeepgramSpeechWAV.canonical(body, sampleRate: Self.sampleRate)
    }

    static func queryItems(for voice: DeepgramSpeechCatalog.Voice) -> [URLQueryItem] {
        [
            URLQueryItem(name: "model", value: voice.id),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "container", value: "wav"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate))
        ]
    }

    /// Maps transport outcomes onto the fixed, credential-free vocabulary.
    static func speechError(from error: Error) -> Error {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return CancellationError()
        }
        if let speechError = error as? DeepgramSpeechError { return speechError }
        switch error as? OpenRouterBoundedResponseTransport.Failure {
        case .responseTooLarge: return DeepgramSpeechError.responseTooLarge
        case .timedOut: return DeepgramSpeechError.timedOut
        case .invalidResponse: return DeepgramSpeechError.invalidResponse
        case nil: break
        }
        if (error as? URLError)?.code == .timedOut { return DeepgramSpeechError.timedOut }
        return DeepgramSpeechError.transportFailure
    }
}
