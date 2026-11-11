import Foundation

/// Canonical identifiers, limits and language support for Rev AI's streaming
/// speech-to-text WebSocket.
///
/// Contract: https://docs.rev.ai/api/streaming/ and
/// https://docs.rev.ai/api/streaming/requests (read 2026-09-10, re-read
/// 2026-09-23). Audio must wait for the `connected` message ("You must wait
/// for this connected message before sending binary audio data"), and the
/// literal `EOS` text message ends it: "On an `EOS` message, Rev AI will
/// return a final hypothesis along with a WebSocket close message." The
/// documented close codes are the 4xxx failures below. Rev AI's own
/// reconnection tutorial (docs.rev.ai/resources/tutorials/
/// recover-connection-streaming-api) restarts a stream on any closure other
/// than 1000, and also on one whose reason is "Reached max session lifetime"
/// (its three-hour limit) whatever the code, so a 1000 closure is the end of a
/// finished stream only when it answers a delivered `EOS`.
public enum RevAIStreaming {
    /// Streaming catalogue identifier. `machine_v2` is Rev AI's own name for
    /// the Reverb model and is the only transcriber value that pins a model
    /// rather than deferring to whatever the account default happens to be.
    public static let liveCatalogID = "revai/machine-v2-streaming"

    static let webSocketHost = "api.rev.ai"
    static let webSocketPath = "/speechtotext/v1/stream"

    /// The `transcriber` query value. Rev AI documents exactly two for
    /// streaming: `machine` (the account default at that moment) and
    /// `machine_v2` (always Reverb). The catalogue pins the second.
    static let transcriber = "machine_v2"

    /// The nine languages Rev AI documents for streaming. Anything outside
    /// this set omits `language`, which the service reads as English.
    public static let supportedLanguageCodes: Set<String> = [
        "en", "fr", "de", "it", "ja", "ko", "cmn", "pt", "es"
    ]

    /// The one deadline that bounds `finishAndWait()` as a whole: any wait for
    /// `connected`, the drain of admitted audio, `EOS`, and the trailing
    /// hypothesis and closure that answer it. A healthy stream ends at that
    /// closure, not here.
    static let finishBudget: TimeInterval = 5

    /// RFC 6455 normal closure: after `EOS`, the only close that ends a stream
    /// successfully.
    static let normalClosureCode = 1_000

    /// The `content_type` for the PCM both platforms capture. Rev AI requires
    /// `layout`, `rate`, `format` and `channels` for `audio/x-raw`, and
    /// `format` is case-sensitive (a GStreamer raw-audio format name).
    public static func rawPCMContentType(sampleRate: Int) -> String {
        "audio/x-raw;layout=interleaved;rate=\(sampleRate);format=S16LE;channels=1"
    }

    /// Resolves a Speak language selection to a code Rev AI documents for
    /// streaming, or `nil` when it cannot serve it.
    ///
    /// Returning `nil` omits the parameter, which Rev AI reads as English.
    /// There is no automatic detection to fall back on, so the system language
    /// is resolved first rather than assuming English (issue #696).
    public static func languageCode(
        for selection: String?,
        systemLocaleIdentifier: String = Locale.current.identifier
    ) -> String? {
        let resolved = TranscriptionLanguageCatalog.localeIdentifier(
            for: TranscriptionLanguageCatalog.normalizedIdentifier(selection),
            systemLocaleIdentifier: systemLocaleIdentifier
        ).localeLanguageCode
        guard !resolved.isEmpty else { return nil }
        if supportedLanguageCodes.contains(resolved) { return resolved }
        // Rev AI writes Mandarin as `cmn`, not `zh`.
        if resolved == "zh" { return "cmn" }
        return nil
    }
}

extension RevAILiveClient {
    /// The stream's documented URL. Rev AI authenticates the socket with an
    /// `access_token` query parameter; `Authorization: Bearer` is documented
    /// only for its HTTP endpoints, so no header is sent. The URL therefore
    /// carries the token and is never logged or put in an error.
    static func webSocketURL(
        accessToken: String,
        sampleRate: Int,
        language: String?,
        systemLocaleIdentifier: String = Locale.current.identifier
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = RevAIStreaming.webSocketHost
        components.path = RevAIStreaming.webSocketPath
        var items = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "content_type", value: RevAIStreaming.rawPCMContentType(sampleRate: sampleRate)),
            URLQueryItem(name: "transcriber", value: RevAIStreaming.transcriber)
        ]
        if let code = RevAIStreaming.languageCode(for: language, systemLocaleIdentifier: systemLocaleIdentifier) {
            items.append(URLQueryItem(name: "language", value: code))
        }
        components.queryItems = items
        return components.url
    }
}

/// Failures the shared Rev AI streaming transport reports.
///
/// Rev AI signals every terminal condition as a WebSocket close code in the
/// 4xxx range, so the code decides the case: a rejected token points the user
/// at Settings and an exhausted balance does not.
public enum RevAIStreamingError: LocalizedError, Equatable {
    /// 4002 — bad `content_type`, over-long `metadata`, or an unknown custom
    /// vocabulary id.
    case badRequest
    /// 4003 — the account does not have the credits to continue. A stored
    /// access token is not credit.
    case insufficientCredits
    /// 4010 / 4013 — the server is shutting down or has no free instance.
    case temporarilyUnavailable(closeCode: Int)
    /// 4029 — concurrent connection limit reached.
    case tooManyConnections
    case closed(closeCode: Int)

    public var errorDescription: String? {
        switch self {
        case .badRequest:
            return "Rev.ai rejected the streaming request. Check the audio format in Settings."
        case .insufficientCredits:
            return "Rev.ai credits exhausted. Top up your Rev.ai account to keep streaming."
        case .temporarilyUnavailable:
            return "Rev.ai has no streaming capacity right now. Try again in a moment."
        case .tooManyConnections:
            return "Rev.ai concurrent streaming limit reached. Close another session and try again."
        case .closed(let closeCode):
            return "Rev.ai closed the streaming connection (code \(closeCode))."
        }
    }

    /// The failure a close frame reports when it did not complete a finished
    /// stream: a documented code names its cause, and any other status,
    /// 1001 and 1005 included, is an unexpected closure. The caller decides
    /// first whether a normal closure (1000) completed the stream.
    static func error(closeCode: Int) -> Error {
        switch closeCode {
        case 4001:
            return StreamingClientError.invalidAPIKey(provider: "Rev.ai")
        case 4002:
            return badRequest
        case 4003:
            return insufficientCredits
        case 4010, 4013:
            return temporarilyUnavailable(closeCode: closeCode)
        case 4029:
            return tooManyConnections
        default:
            return closed(closeCode: closeCode)
        }
    }
}

/// Lifecycle failures of the shared Rev AI client that no close code names.
/// Hosts show `errorDescription`; nothing here carries a token or transcript.
enum RevAILiveError: LocalizedError, Equatable {
    /// `connected` did not arrive in time, so no audio could be sent.
    case sessionNotReady
    /// `EOS` was delivered, but the stream never closed within the finish budget.
    case missingCompletion
    /// The server closed normally before the recording's `EOS` was delivered,
    /// so audio after that point was never transcribed.
    case unexpectedCompletion
    /// The server closed normally after `EOS` while the last partial hypothesis
    /// still had no final, so its words were never confirmed.
    case incompleteSegment
    /// PCM16 is two bytes per sample; a partial sample would misalign every
    /// sample after it.
    case invalidPCM

    var errorDescription: String? {
        switch self {
        case .sessionNotReady:
            return "Rev.ai did not start the streaming session in time."
        case .missingCompletion:
            return "Rev.ai did not complete the transcription in time. The recording is available to retry."
        case .unexpectedCompletion:
            return "Rev.ai ended the stream before the recording finished. The recording is available to retry."
        case .incompleteSegment:
            return "Rev.ai closed the stream before confirming the last words. The recording is available to retry."
        case .invalidPCM:
            return "Rev.ai requires complete 16-bit PCM samples."
        }
    }
}

/// One decoded Rev AI streaming server frame.
///
/// Rev AI has exactly three frame types. Anything else decodes to `nil` and is
/// ignored, because an unrecognised frame must never end a live recording. A
/// hypothesis without words decodes to empty text rather than `nil`: an empty
/// final still ends its segment, and an empty partial withdraws the words the
/// previous one showed.
///
/// The two transcript cases are reconstructed differently on purpose: a `final`
/// carries `punct` elements that hold the spacing *and* the punctuation, so its
/// values concatenate with nothing between them, while a `partial` carries no
/// `punct` elements at all and must be joined with single spaces. One shared
/// routine would be wrong for one of the two.
enum RevAIStreamingEvent: Equatable {
    case connected
    case partial(String)
    case final(String)

    /// Decodes one frame from the injected transport. Rev AI sends JSON text;
    /// JSON in a binary frame is read the same way, and anything else is ignored.
    init?(message: StreamingWebSocketMessage) {
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .binary(let bytes): data = bytes
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.init(object: object)
    }

    init?(object: [String: Any]) {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "connected":
            self = .connected
        case "partial":
            self = .partial(Self.partialText(from: object) ?? "")
        case "final":
            self = .final(Self.finalText(from: object) ?? "")
        default:
            return nil
        }
    }

    /// Concatenates every element value with nothing between them: a literal
    /// `" "` arrives as its own `punct` element, so a separator would produce
    /// "One  two ." instead of "One two.".
    static func finalText(from object: [String: Any]) -> String? {
        Self.nonBlank(elements(in: object).map(\.value).joined())
    }

    /// Joins the word values with single spaces, because a partial carries no
    /// `punct` elements to supply them.
    static func partialText(from object: [String: Any]) -> String? {
        Self.nonBlank(
            elements(in: object).filter { $0.type == "text" }.map(\.value).joined(separator: " ")
        )
    }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func elements(in object: [String: Any]) -> [(type: String, value: String)] {
        guard let raw = object["elements"] as? [[String: Any]] else { return [] }
        return raw.compactMap { element in
            guard let value = element["value"] as? String else { return nil }
            return (type: (element["type"] as? String) ?? "text", value: value)
        }
    }
}
