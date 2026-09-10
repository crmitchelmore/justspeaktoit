#if os(iOS)
import Foundation
import SpeakCore

/// What a `justspeaktoit://` URL asked the app to do with the recorder.
public enum CaptureDeepLinkAction: String, Equatable, Sendable, CaseIterable {
    /// Start a recording. A no-op when one is already running, so a caller that
    /// fires twice cannot start two sessions.
    case start
    /// Stop the running recording and route the transcript to its destination.
    case stop
    /// Stop if a recording (or a start-up) is in flight, otherwise start.
    case toggle
    /// One-shot capture that returns the transcript to the caller: start, stop
    /// at `maxDuration` (or when the user stops it), then open the caller's
    /// `x-success` URL with the text. The only verb that carries a callback.
    case dictate
}

/// A parsed capture deep link: the verb, plus the overrides that apply to this
/// one capture.
///
/// A link that named something the app does not recognise still parses, with
/// `failure` set: the caller has to be told why nothing happened, and dropping
/// the link would leave an x-callback caller waiting for a return that can
/// never arrive.
public struct CaptureDeepLink: Equatable, Sendable {
    public let action: CaptureDeepLinkAction
    /// Overrides `AppSettings.hardwareTriggerDestination` for this capture only.
    /// `nil` means "use whatever the user configured".
    public let destination: HardwareTriggerDestination?
    /// Where to return the transcript. Only ever set on `dictate`.
    public let callback: CaptureCallback?
    /// `lang=` — a `TranscriptionLanguageCatalog` identifier for this capture.
    public let languageIdentifier: String?
    /// `model=` — a `ModelCatalog` transcription identifier for this capture.
    public let modelIdentifier: String?
    /// `maxDuration=` — seconds after which a `dictate` stops itself.
    public let maxDuration: TimeInterval?
    /// Set when the link is well-formed enough to answer but must not record.
    public let failure: CaptureLinkFailure?

    public init(
        action: CaptureDeepLinkAction,
        destination: HardwareTriggerDestination? = nil,
        callback: CaptureCallback? = nil,
        languageIdentifier: String? = nil,
        modelIdentifier: String? = nil,
        maxDuration: TimeInterval? = nil,
        failure: CaptureLinkFailure? = nil
    ) {
        self.action = action
        self.destination = destination
        self.callback = callback
        self.languageIdentifier = languageIdentifier
        self.modelIdentifier = modelIdentifier
        self.maxDuration = maxDuration
        self.failure = failure
    }

    /// How long a `dictate` runs before stopping itself.
    public var dictateDuration: TimeInterval {
        self.maxDuration ?? CaptureLinkParameters.defaultDictateDuration
    }
}

// MARK: - Parsing

public extension CaptureDeepLink {
    /// The URL scheme the app registers (`Project.swift`, `CFBundleURLSchemes`).
    static let scheme = "justspeaktoit"

    /// Parses a capture verb out of a deep link, or returns `nil` when the URL
    /// is not a capture command (a tab link, or anything else).
    ///
    /// Accepted spellings, so that both a dedicated URL and the widget's
    /// iOS 17 fallback resolve to the same command:
    ///
    ///     justspeaktoit://start
    ///     justspeaktoit://stop
    ///     justspeaktoit://toggle
    ///     justspeaktoit://dictate
    ///     justspeaktoit://transcribe?action=start
    ///     justspeaktoit://x-callback-url/dictate?x-success=drafts://create?text=
    ///
    /// The optional `destination` query item takes a `HardwareTriggerDestination`
    /// raw value (`clipboard`, `clipboardAndPostProcess`, `historyOnly`) or one
    /// of the friendlier aliases `polish` and `history`. An unrecognised value is
    /// ignored rather than failing the whole link, so a typo in an automation
    /// still records — it just uses the configured destination.
    ///
    /// `lang` and `model` apply to a capture this link starts; `maxDuration` and
    /// the `x-success` / `x-error` / `x-cancel` callbacks apply to `dictate`
    /// only. Unlike `destination`, an unrecognised value for any of these fails
    /// the link (`failure` is set and nothing records): recording with a
    /// different model or language than the caller named, or ignoring a callback
    /// the caller is waiting on, is a silent wrong answer.
    ///
    /// Parsing is pure and has no side effects; performing the command is
    /// `CaptureCommandRunner`'s job.
    static func parse(_ url: URL) -> CaptureDeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        guard let action = self.action(for: url, queryItems: queryItems) else { return nil }
        return self.resolve(action: action, queryItems: queryItems)
    }

    /// The x-callback-url wrapper host, which carries the verb in its path.
    static let xCallbackHost = "x-callback-url"

    private static func action(
        for url: URL,
        queryItems: [URLQueryItem]
    ) -> CaptureDeepLinkAction? {
        let host = url.host?.lowercased()
        if let host, let direct = CaptureDeepLinkAction(rawValue: host) { return direct }
        switch host {
        case xCallbackHost:
            // justspeaktoit://x-callback-url/dictate — the spec puts the verb in
            // the first path component.
            return url.pathComponents
                .first { $0 != "/" }
                .map { $0.lowercased() }
                .flatMap(CaptureDeepLinkAction.init(rawValue:))
        case "transcribe":
            // The widget and any other surface that only owns a tab link can
            // add ?action=start rather than needing a second URL host.
            return queryItems
                .first { $0.name.lowercased() == "action" }
                .flatMap { $0.value?.lowercased() }
                .flatMap(CaptureDeepLinkAction.init(rawValue:))
        default:
            return nil
        }
    }

    private static func resolve(
        action: CaptureDeepLinkAction,
        queryItems: [URLQueryItem]
    ) -> CaptureDeepLink {
        let destination = self.destination(from: queryItems)
        func value(_ name: String) -> String? {
            queryItems.first { $0.name.lowercased() == name }?.value
        }
        func refuse(_ failure: CaptureLinkFailure, _ callback: CaptureCallback?) -> CaptureDeepLink {
            CaptureDeepLink(
                action: action,
                destination: destination,
                callback: callback,
                failure: failure
            )
        }

        let callback: CaptureCallback?
        do {
            callback = try CaptureCallback.parse(queryItems: queryItems)
        } catch {
            // The callback itself is the thing that was wrong, so there is
            // nowhere safe to send the error: only the in-app alert reports it.
            return refuse(.invalidCallback, nil)
        }

        // A callback on `stop` would let any app redirect a dictation it did not
        // start into its own text field — the same hole the destination override
        // is closed against — and on `start`/`toggle` there is no result to
        // return. Both are refused rather than ignored.
        let wantsDictateOnly = callback != nil || value("maxduration") != nil
        if action != .dictate, wantsDictateOnly {
            return refuse(.unsupportedParameter, callback)
        }
        if action == .stop, value("lang") != nil || value("model") != nil {
            return refuse(.unsupportedParameter, callback)
        }

        switch self.captureSettings(from: queryItems) {
        case .failure(let failure):
            return refuse(failure, callback)
        case .success(let settings):
            return CaptureDeepLink(
                action: action,
                destination: destination,
                callback: callback,
                languageIdentifier: settings.language,
                modelIdentifier: settings.model,
                maxDuration: settings.maxDuration
            )
        }
    }

    private struct CaptureSettings {
        var language: String?
        var model: String?
        var maxDuration: TimeInterval?
    }

    /// Validates `lang`, `model` and `maxDuration`. Each is either a value the
    /// catalogues recognise or a failure — never a quiet substitution.
    private static func captureSettings(
        from queryItems: [URLQueryItem]
    ) -> Result<CaptureSettings, CaptureLinkFailure> {
        func value(_ name: String) -> String? {
            queryItems.first { $0.name.lowercased() == name }?.value
        }

        var settings = CaptureSettings()
        if let raw = value("lang") {
            guard let resolved = CaptureLinkParameters.language(from: raw) else {
                return .failure(.unknownLanguage)
            }
            settings.language = resolved
        }
        if let raw = value("model") {
            guard let resolved = CaptureLinkParameters.model(from: raw) else {
                return .failure(.unknownModel)
            }
            settings.model = resolved
        }
        if let raw = value("maxduration") {
            guard let resolved = CaptureLinkParameters.duration(from: raw) else {
                return .failure(.invalidMaxDuration)
            }
            settings.maxDuration = resolved
        }
        return .success(settings)
    }

    private static func destination(from queryItems: [URLQueryItem]) -> HardwareTriggerDestination? {
        guard let raw = queryItems
            .first(where: { $0.name.lowercased() == "destination" })?
            .value?
            .trimmingCharacters(in: .whitespaces),
            !raw.isEmpty
        else { return nil }

        if let exact = HardwareTriggerDestination(rawValue: raw) { return exact }
        switch raw.lowercased() {
        case "polish", "clipboardandpostprocess": return .clipboardAndPostProcess
        case "history", "historyonly": return .historyOnly
        case "clipboard": return .clipboard
        default: return nil
        }
    }
}
#endif
