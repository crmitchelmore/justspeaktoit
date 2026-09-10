import Foundation

/// Canonical identifiers, limits and language support for Rev AI's streaming
/// speech-to-text WebSocket.
///
/// Contract: https://docs.rev.ai/api/streaming/ and
/// https://docs.rev.ai/api/streaming/requests (read 2026-09-10).
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

    /// How long `finishAndWait()` waits for the trailing hypothesis and the
    /// server's close after `EOS`.
    static let finishBudget: TimeInterval = 5

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

    /// Maps a documented close code. `nil` for codes that are not a failure
    /// (a normal close after `EOS`) or that carry no Rev AI meaning.
    static func forCloseCode(_ closeCode: Int) -> Error? {
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
        case 1000, 1001, 1005, 0:
            return nil
        default:
            return closed(closeCode: closeCode)
        }
    }
}

/// One decoded Rev AI streaming server frame.
///
/// Rev AI has exactly three frame types. Anything else decodes to `nil` and is
/// ignored, because an unrecognised frame must never end a live recording.
///
/// The two transcript cases are reconstructed differently on purpose: a `final`
/// carries `punct` elements that hold the spacing *and* the punctuation, so its
/// values concatenate with nothing between them, while a `partial` carries no
/// `punct` elements at all and must be joined with single spaces. One shared
/// routine would be wrong for one of the two.
enum RevAIStreamingEvent {
    case connected
    case partial(String)
    case final(String)

    init?(object: [String: Any]) {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "connected":
            self = .connected
        case "partial":
            guard let text = Self.partialText(from: object) else { return nil }
            self = .partial(text)
        case "final":
            guard let text = Self.finalText(from: object) else { return nil }
            self = .final(text)
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
