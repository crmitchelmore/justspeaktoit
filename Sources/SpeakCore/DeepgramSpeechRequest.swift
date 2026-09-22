import Foundation

/// One immutable Deepgram voice-output request.
///
/// Every value is captured at construction, so later changes to the caller's
/// settings or pronunciation dictionary never affect a request already made.
/// The voice is always a canonical `DeepgramSpeechCatalog` entry: no caller
/// string reaches the provider. This first execution path speaks at the
/// provider's natural rate with one fixed lossless format; another speed is
/// refused rather than ignored.
public struct DeepgramSpeechRequest: Equatable, Sendable {
    /// Deepgram synthesizes at most 2,000 characters per request. Counted as
    /// Unicode scalars of the text actually sent, after pronunciation and
    /// trimming. Longer text is refused, never truncated.
    public static let maximumCharacters = 2_000

    public let text: String
    public let voice: DeepgramSpeechCatalog.Voice
    /// Applied in order with the dictionary manager's `applyReplacements`
    /// semantics. Deepgram has no SSML phoneme support.
    public let pronunciation: [PronunciationEntry]

    /// - Parameter speed: Only 1, the provider's natural rate, is available.
    ///   Any other value, including a non-finite one, throws
    ///   `DeepgramSpeechError.unsupportedSpeed`.
    public init(
        text: String,
        voice: DeepgramSpeechCatalog.Voice,
        pronunciation: [PronunciationEntry] = [],
        speed: Double = 1
    ) throws {
        guard DeepgramSpeechCatalog.voices.contains(voice) else { throw DeepgramSpeechError.unknownVoice }
        guard speed == 1 else { throw DeepgramSpeechError.unsupportedSpeed }
        self.text = text
        self.voice = voice
        self.pronunciation = pronunciation
    }

    /// Resolves stored identifiers through the canonical catalogue, keeping
    /// its legacy model, short-name, provider-prefix and invalid-pair
    /// migrations. `voice` reports the voice that will actually speak.
    public init(
        text: String,
        modelID: String?,
        voiceID: String?,
        pronunciation: [PronunciationEntry] = [],
        speed: Double = 1
    ) throws {
        try self.init(
            text: text,
            voice: DeepgramSpeechCatalog.resolvedSelection(modelID: modelID, voiceID: voiceID).voice,
            pronunciation: pronunciation,
            speed: speed
        )
    }
}

/// Failures of Deepgram voice output. Messages never include the API key, the
/// request text or a provider response body.
public enum DeepgramSpeechError: Error, Equatable, Sendable {
    /// Not a canonical catalogue voice.
    case unknownVoice
    /// Only the provider's natural rate is available in this execution path.
    case unsupportedSpeed
    /// The text, after pronunciation, exceeds the per-request limit.
    case textTooLong(characterCount: Int, limit: Int)
    /// The supplied credential is empty.
    case missingCredential
    /// The supplied credential contains whitespace, control or non-ASCII
    /// characters, or is implausibly long.
    case invalidCredential
    /// HTTP 401/403.
    case unauthorized(statusCode: Int)
    /// Any other non-2xx status. The provider body is never read.
    case httpStatus(Int)
    case responseTooLarge
    case timedOut
    case invalidResponse
    case transportFailure
    case emptyAudio
    /// Every sample was zero: nothing audible would be spoken.
    case silentAudio
    /// Not mono 16-bit linear PCM WAV at the requested rate.
    case unsupportedAudioFormat
}

extension DeepgramSpeechError: LocalizedError {
    // One fixed, credential-free sentence per case.
    public var errorDescription: String? {
        switch self {
        case .unknownVoice:
            return "Choose a Deepgram voice from the catalogue."
        case .unsupportedSpeed:
            return "Deepgram voice output currently speaks only at normal speed."
        case let .textTooLong(characterCount, limit):
            return "Voice output accepts at most \(limit) characters per request; this text has \(characterCount)."
        case .missingCredential:
            return "Add a Deepgram API key to use voice output."
        case .invalidCredential:
            return "The Deepgram API key is not valid. Save it again."
        case .unauthorized(let statusCode):
            return "Deepgram rejected the API key (HTTP \(statusCode))."
        case .httpStatus(let statusCode):
            return "Deepgram could not synthesize speech (HTTP \(statusCode))."
        case .responseTooLarge:
            return "Deepgram returned more audio than voice output accepts."
        case .timedOut:
            return "Deepgram did not finish synthesizing speech in time."
        case .invalidResponse:
            return "Deepgram returned an invalid response."
        case .transportFailure:
            return "Deepgram could not be reached."
        case .emptyAudio:
            return "Deepgram returned no audio."
        case .silentAudio:
            return "Deepgram returned only silence."
        case .unsupportedAudioFormat:
            return "Deepgram returned audio in an unexpected format."
        }
    }
}
