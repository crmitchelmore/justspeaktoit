import Foundation

// MARK: - Failures

/// Why a capture link was refused, or why a capture it started produced no
/// transcript.
///
/// The raw value is the `errorCode` handed back to an x-callback-url caller;
/// `errorDescription` is both the `errorMessage` and the text the app shows the
/// user, because a refusal has to be visible on both sides — the caller cannot
/// see an alert and the user cannot see a callback.
public enum CaptureLinkFailure: String, Error, LocalizedError, Equatable, Sendable, CaseIterable {
    /// `model=` named something outside the transcription catalogue.
    case unknownModel
    /// `lang=` named something outside the language catalogue.
    case unknownLanguage
    /// `maxDuration=` was not a number, or fell outside the allowed range.
    case invalidMaxDuration
    /// An `x-success` / `x-error` / `x-cancel` value was missing, malformed, or
    /// used a scheme the app refuses to open.
    case invalidCallback
    /// A parameter that only `dictate` supports was used on another verb.
    case unsupportedParameter
    /// The device was locked, so the microphone must not open.
    case deviceLocked
    /// The app was not foreground, so the microphone must not open.
    case notForeground
    /// A capture was already running; a link must never start a second one.
    case alreadyRecording
    /// The recorder refused or threw while starting.
    case recordingFailed
    /// The same capture parameter was supplied more than once with different
    /// values, so there is no unambiguous request to honour.
    case repeatedParameter
    /// `model=` named a model this device cannot run right now — typically no
    /// API key for its provider. Refused rather than quietly substituted.
    case modelUnavailable
    /// The capture started but ended in a provider or recording error, so its
    /// transcript is not the caller's answer.
    case transcriptionFailed
    /// The request was queued during a cold launch and a later capture link
    /// replaced it before the app was ready to act on either.
    case superseded

    public var errorDescription: String? {
        switch self {
        case .unknownModel:
            return "That transcription model is not one this app knows. The recording was not started."
        case .unknownLanguage:
            return "That language is not one this app knows. The recording was not started."
        case .invalidMaxDuration:
            return "maxDuration must be a number of seconds between "
                + "\(Int(CaptureLinkParameters.durationRange.lowerBound)) and "
                + "\(Int(CaptureLinkParameters.durationRange.upperBound))."
        case .invalidCallback:
            return "The callback URL was missing, malformed, or used a scheme this app will not open."
        case .unsupportedParameter:
            return "Callback, destination, language, model and maxDuration parameters are only "
                + "supported on the verb that starts the capture they apply to."
        case .deviceLocked:
            return "Unlock the device before starting a dictation from a link."
        case .notForeground:
            return "A link can only start a recording with the app open in front of you."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .recordingFailed:
            return "The recording could not be started."
        case .repeatedParameter:
            return "A capture parameter was given more than once with conflicting values. "
                + "The recording was not started."
        case .modelUnavailable:
            return "That transcription model is not available on this device — check its API key. "
                + "The recording was not started, because it would have used a different model."
        case .transcriptionFailed:
            return "The recording failed before it produced a transcript."
        case .superseded:
            return "A later capture link replaced this request before the app could act on it."
        }
    }
}

// MARK: - Parameters

/// Pure validation for the `lang`, `model` and `maxDuration` query parameters.
///
/// Every one of these returns `nil` for a value it does not recognise, and the
/// caller turns that into a visible failure. Nothing here falls back to a
/// default: silently recording with a different model or language than the
/// caller asked for is worse than refusing, because the caller cannot tell.
///
/// `language`, `model` and `requiresBatchMode` were duplicated verbatim in
/// `CaptureParameterResolution` while the URL surface (#1070) and the
/// parameterised-intent surface (#1076) were open in parallel and could not
/// import each other. Both landed together, so this side now forwards: there
/// is exactly one implementation, and `lang=en_GB` in a URL and
/// "Language: English (United Kingdom)" in a Shortcut cannot drift apart.
/// `maxDuration` has no counterpart there and stays here.
public enum CaptureLinkParameters {
    /// Bounds on `maxDuration`, in seconds. The lower bound keeps a link from
    /// arming a recording that stops before the microphone is warm; the upper
    /// bound is a backstop against a link that leaves the microphone hot.
    public static let durationRange: ClosedRange<TimeInterval> = 1...600

    /// Used when a `dictate` link does not set `maxDuration`. A one-shot
    /// dictation always has a deadline — an unbounded one would leave the
    /// caller waiting forever and the microphone open.
    public static let defaultDictateDuration: TimeInterval = 120

    /// Accepts a language identifier from the catalogue (`en_US`, and `en-US`
    /// for callers that write BCP-47 with a hyphen), or `auto`/`automatic` for
    /// provider-side detection.
    ///
    /// A bare `en` is rejected on purpose: the catalogue holds four English
    /// locales and picking one would be exactly the silent substitution this
    /// parameter must not make.
    public static func language(from raw: String) -> String? {
        CaptureParameterResolution.language(from: raw)
    }

    /// Accepts a transcription model identifier that the catalogue lists for
    /// live or batch transcription. The "custom model" placeholder is not a
    /// real identifier, so it is rejected too.
    public static func model(from raw: String) -> String? {
        CaptureParameterResolution.model(from: raw)
    }

    /// Whether the identifier is a batch-only model, so the capture has to run
    /// in batch mode however the app is configured. `false` when the model is
    /// available live, which leaves the configured mode alone.
    public static func requiresBatchMode(_ modelID: String) -> Bool {
        CaptureParameterResolution.requiresBatchMode(modelID)
    }

    /// Accepts a whole or fractional number of seconds inside `durationRange`.
    public static func duration(from raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let seconds = TimeInterval(trimmed), seconds.isFinite,
              durationRange.contains(seconds)
        else { return nil }
        return seconds
    }
}

// MARK: - Policy

/// The refusal rules a capture link has to pass before a microphone opens.
/// Pure, so the locked-device and single-flight rules are unit-tested on the
/// host rather than only being reachable on a device.
public enum CaptureLinkPolicy {
    /// - Parameters:
    ///   - isProtectedDataAvailable: `UIApplication.isProtectedDataAvailable`,
    ///     which is false while the device is locked.
    ///   - isAppActive: whether the scene is foreground-active. Any app can
    ///     open the scheme, so the microphone only ever opens with this app
    ///     visibly in front of the user.
    ///   - isCaptureBusy: whether a capture (or a start still in flight) is
    ///     already running anywhere in the process. Starting a second one is
    ///     issue #943: two sessions against one input and a hot microphone
    ///     nobody owns.
    /// - Returns: the reason to refuse, or `nil` to proceed.
    public static func refusal(
        isProtectedDataAvailable: Bool,
        isAppActive: Bool,
        isCaptureBusy: Bool
    ) -> CaptureLinkFailure? {
        if !isProtectedDataAvailable { return .deviceLocked }
        if !isAppActive { return .notForeground }
        if isCaptureBusy { return .alreadyRecording }
        return nil
    }
}

// MARK: - Callback

/// The x-callback-url triple a `dictate` link can carry.
///
/// Building the return URL is pure and lives here so the encoding, the length
/// cap and the scheme rules are all unit-tested; opening the result is the
/// caller's job.
public struct CaptureCallback: Equatable, Sendable {
    public let success: URL?
    public let error: URL?
    public let cancel: URL?

    public init(success: URL? = nil, error: URL? = nil, cancel: URL? = nil) {
        self.success = success
        self.error = error
        self.cancel = cancel
    }

    public var isEmpty: Bool { self.success == nil && self.error == nil && self.cancel == nil }

    // MARK: Limits

    /// Longest transcript handed back through a callback URL, in characters.
    ///
    /// A URL is a poor transport for a long document: every byte is
    /// percent-encoded (an emoji becomes 16 characters), the receiving app
    /// decides its own limit, and iOS gives no error when an over-long URL is
    /// dropped. 4,000 characters is roughly 700 words — several minutes of
    /// speech — and stays near 12KB even when every character needs escaping.
    /// The full transcript is never lost: it still goes to the capture's
    /// destination (clipboard, polish or history) exactly as it would without
    /// a callback.
    public static let maxTranscriptCharacters = 4_000

    /// Appended to a transcript that hit the cap, so the caller can see the
    /// text is partial even if it ignores the `truncated` parameter.
    public static let truncationMarker = "… [truncated]"

    /// Longest callback URL accepted from a caller, before the transcript is
    /// added.
    public static let maxCallbackLength = 2_048

    // MARK: Building

    /// The URL to open when a dictation produced text.
    ///
    /// The transcript is added as a `text` parameter, or concatenated when the
    /// callback ends in `=` — the `drafts://create?text=` prefix idiom that
    /// URL-only tools are written against. `truncated=true` is added when the
    /// cap bit.
    public func successURL(transcript: String) -> URL? {
        guard let success = self.success else { return nil }
        let capped = Self.capped(transcript)
        var items = [(name: "text", value: capped.text)]
        if capped.truncated { items.append((name: "truncated", value: "true")) }
        return Self.appending(items, to: success)
    }

    /// The URL to open when the request was refused or the capture failed.
    public func errorURL(_ failure: CaptureLinkFailure) -> URL? {
        guard let error = self.error else { return nil }
        return Self.appending(
            [
                (name: "errorCode", value: failure.rawValue),
                (name: "errorMessage", value: failure.errorDescription ?? failure.rawValue)
            ],
            to: error
        )
    }

    /// The URL to open when the dictation finished with nothing said. Carries
    /// no parameters, per the x-callback-url convention.
    public var cancelURL: URL? { self.cancel }

    /// Truncates to `maxTranscriptCharacters`, marker included, on a character
    /// boundary.
    public static func capped(_ transcript: String) -> (text: String, truncated: Bool) {
        guard transcript.count > maxTranscriptCharacters else { return (transcript, false) }
        let keep = maxTranscriptCharacters - truncationMarker.count
        let head = String(transcript.prefix(max(keep, 0)))
        return (head + truncationMarker, true)
    }

    /// Percent-encodes with the unreserved set of RFC 3986, so `&`, `=`, `#`,
    /// `%`, `+`, `?`, spaces, newlines and every multi-byte character are
    /// escaped. `URLComponents.queryItems` leaves several of those alone, which
    /// is how a transcript containing an ampersand silently becomes two
    /// parameters in the caller's app.
    public static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }

    private static let unreservedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set.intersection(.urlQueryAllowed)
    }()

    private static func appending(_ items: [(name: String, value: String)], to url: URL) -> URL? {
        let raw = url.absoluteString
        let encoded = items.map { "\(percentEncoded($0.name))=\(percentEncoded($0.value))" }
        // `drafts://create?text=` — a query whose last value is deliberately
        // empty is a prefix waiting for the value, not a parameter to repeat.
        if raw.contains("?"), raw.hasSuffix("="), let first = items.first {
            let rest = encoded.dropFirst().map { "&" + $0 }.joined()
            return URL(string: raw + percentEncoded(first.value) + rest)
        }
        let separator = raw.contains("?") ? "&" : "?"
        return URL(string: raw + separator + encoded.joined(separator: "&"))
    }

    // MARK: Parsing

    /// Pulls `x-success`, `x-error` and `x-cancel` out of a link's query.
    ///
    /// - Throws: `CaptureLinkFailure.invalidCallback` when a parameter is
    ///   present but unusable. A bad callback is never dropped quietly: a
    ///   caller that thinks it passed `x-success` would otherwise wait forever
    ///   for a return that can never come.
    /// - Throws: `CaptureLinkFailure.repeatedParameter` when the same callback
    ///   was supplied twice with different values — a caller expecting a return
    ///   at one of two addresses must be told, not sent to whichever came first.
    public static func parse(queryItems: [URLQueryItem]) throws -> CaptureCallback? {
        func callback(_ name: String) throws -> URL? {
            guard CaptureLinkQuery.isPresent(name, in: queryItems) else { return nil }
            // A repeat throws `.repeatedParameter` from here, deliberately
            // ahead of the `.invalidCallback` the value check would report.
            guard let raw = try CaptureLinkQuery.singleValue(name, in: queryItems),
                  let url = validated(raw) else {
                throw CaptureLinkFailure.invalidCallback
            }
            return url
        }

        let parsed = CaptureCallback(
            success: try callback("x-success"),
            error: try callback("x-error"),
            cancel: try callback("x-cancel")
        )
        return parsed.isEmpty ? nil : parsed
    }

    /// Schemes the app refuses to open, whatever a caller asks for.
    ///
    /// - `http`/`https` because an https callback is how a transcript leaves
    ///   the device — either to a web server or, as a Universal Link, to
    ///   whichever app claims that domain. A dictation goes to another app on
    ///   this phone or nowhere.
    /// - `javascript`, `data`, `file`, `blob`, `about`, `vbscript` because they
    ///   address content rather than an app.
    /// - `tel`, `sms`, `facetime`, `mailto` because a link should not be able
    ///   to make the app place a call or address a message.
    /// - the app's own scheme, so a callback cannot re-enter the app and loop.
    public static let refusedSchemes: Set<String> = [
        "http", "https", "javascript", "data", "file", "blob", "about", "vbscript",
        "tel", "telprompt", "sms", "facetime", "facetime-audio", "mailto", "justspeaktoit"
    ]

    /// Validates a caller-supplied callback before the app will ever open it.
    ///
    /// Returns `nil` for anything that is not a plainly-formed custom app
    /// scheme URL: that, rather than a deny-list alone, is what stops a caller
    /// turning this app into a way to open an arbitrary URL.
    public static func validated(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxCallbackLength else { return nil }
        // A fragment would sit after any parameters the app appends, and
        // control characters or spaces mean the string is not a URL at all.
        guard !trimmed.contains("#") else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value != 0x7F })
        else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        guard !refusedSchemes.contains(scheme) else { return nil }
        guard isWellFormedScheme(scheme) else { return nil }
        // `scheme:` alone addresses nothing; require an app URL with a body.
        guard trimmed.count > scheme.count + 1 else { return nil }
        return url
    }

    private static func isWellFormedScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(first)
        else { return false }
        var allowed = CharacterSet.lowercaseLetters
        allowed.insert(charactersIn: "0123456789+-.")
        return scheme.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
