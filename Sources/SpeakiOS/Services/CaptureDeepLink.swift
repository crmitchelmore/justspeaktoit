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
}

/// A parsed capture deep link: the verb, plus an optional destination override
/// for this one capture.
public struct CaptureDeepLink: Equatable, Sendable {
    public let action: CaptureDeepLinkAction
    /// Overrides `AppSettings.hardwareTriggerDestination` for this capture only.
    /// `nil` means "use whatever the user configured".
    public let destination: HardwareTriggerDestination?

    public init(action: CaptureDeepLinkAction, destination: HardwareTriggerDestination? = nil) {
        self.action = action
        self.destination = destination
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
    ///     justspeaktoit://transcribe?action=start
    ///
    /// The optional `destination` query item takes a `HardwareTriggerDestination`
    /// raw value (`clipboard`, `clipboardAndPostProcess`, `historyOnly`) or one
    /// of the friendlier aliases `polish` and `history`. An unrecognised value is
    /// ignored rather than failing the whole link, so a typo in an automation
    /// still records — it just uses the configured destination.
    ///
    /// Parsing is pure and has no side effects; performing the command is
    /// `CaptureCommandRunner`'s job.
    static func parse(_ url: URL) -> CaptureDeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let host = url.host?.lowercased()
        let action: CaptureDeepLinkAction?
        if let host, let direct = CaptureDeepLinkAction(rawValue: host) {
            action = direct
        } else if host == "transcribe" {
            // The widget and any other surface that only owns a tab link can
            // add ?action=start rather than needing a second URL host.
            action = queryItems
                .first { $0.name.lowercased() == "action" }
                .flatMap { $0.value?.lowercased() }
                .flatMap(CaptureDeepLinkAction.init(rawValue:))
        } else {
            action = nil
        }

        guard let action else { return nil }
        return CaptureDeepLink(action: action, destination: destination(from: queryItems))
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
