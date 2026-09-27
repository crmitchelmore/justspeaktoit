import Foundation
import SpeakCore

/// What a desktop app is asked to do when it is launched with a link, or when
/// a second launch forwards one to the running window.
public enum DesktopActivationRequest: Equatable, Sendable {
    /// Bring the window forward; nothing else changes.
    case show
    /// A recorder command, as the iPhone app's `start`, `stop` and `toggle` links.
    case capture(DesktopCaptureCommand)
    /// Apple's web sign-in finished and handed back the CloudKit web auth token
    /// (the custom-scheme sign-in callback).
    case cloudKitSignIn(webAuthToken: String)
}

/// The recorder verbs a desktop link can carry. They mean what the iPhone
/// app's capture links mean: `start` does nothing while a recording runs,
/// `stop` does nothing without one and `toggle` does whichever applies.
public enum DesktopCaptureCommand: String, Equatable, Sendable, CaseIterable {
    case start
    case stop
    case toggle
}

/// Why a link was refused. The message is shown in the window's status line.
public struct DesktopActivationLinkError: Error, Equatable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

/// Parses the `justspeaktoit://` links a desktop app accepts.
///
/// The vocabulary is the iPhone app's (`Sources/SpeakiOS/Services/DeepLinkRouter.swift`
/// and `CaptureDeepLink.swift`); the macOS app registers no URL scheme. A
/// desktop build answers the subset it can perform:
///
///     justspeaktoit://                         → show the window
///     justspeaktoit://open, ://transcribe      → show the window
///     justspeaktoit://start | stop | toggle    → recorder command
///     justspeaktoit://transcribe?action=start  → same, for tab-style links
///     justspeaktoit://cloudkit-sign-in?ckWebAuthToken=…
///                                              → iCloud sign-in callback
///
/// Everything else is refused with a reason rather than ignored, as the iPhone
/// app refuses what it cannot honour: `dictate` and `x-callback-url` (which
/// return text to the calling app), `openclaw` (an iPhone-only feature), and
/// the per-capture `destination`, `lang` and `model` options, which a desktop
/// recording cannot apply yet. Recording with settings other than the ones the
/// link named would be a silent wrong answer.
///
/// Parsing is pure. Any web page can open such a link, so a browser asks
/// before it launches the app, and a link can only do what the window's own
/// Record button does.
public enum DesktopActivationLink {
    /// The route of the custom-scheme iCloud sign-in callback.
    public static let cloudKitSignInRoute = "cloudkit-sign-in"
    /// The query item Apple's sign-in redirect adds to the callback.
    public static let webAuthTokenItem = "ckWebAuthToken"
    /// Longer links are refused before parsing; a real one is far shorter.
    public static let maximumLength = 8_192

    private static let showRoutes: Set<String> = ["", "open", "transcribe"]
    private static let unsupportedCaptureOptions = ["destination", "lang", "model", "maxduration"]

    /// The request `text` asks for, or a refusal naming why it cannot be done.
    public static func parse(
        _ text: String,
        scheme: String = ReleaseTrain.current.urlScheme
    ) throws -> DesktopActivationRequest {
        let components = try validatedComponents(text, scheme: scheme)
        let route = (components.host ?? "").lowercased()
        let path = components.path
        let items = components.queryItems ?? []
        switch route {
        case cloudKitSignInRoute:
            return try signIn(path: path, items: items)
        case "x-callback-url", "dictate":
            throw DesktopActivationLinkError(
                "Dictate links that return text to another app are not available on Windows yet."
            )
        case "openclaw":
            throw DesktopActivationLinkError("OpenClaw is an iPhone feature and is not available on Windows.")
        default:
            guard path.isEmpty || path == "/" else {
                throw DesktopActivationLinkError(
                    "Just Speak to It does not recognise the link \(scheme)://\(route)\(path)."
                )
            }
            return try windowRequest(route: route, items: items, scheme: scheme)
        }
    }

    /// The link's parts, once its size, characters, scheme and unused parts pass.
    private static func validatedComponents(_ text: String, scheme: String) throws -> URLComponents {
        guard text.utf8.count <= maximumLength,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw DesktopActivationLinkError("The link is too long or contains control characters.")
        }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == scheme.lowercased() else {
            throw DesktopActivationLinkError("Only \(scheme):// links open Just Speak to It.")
        }
        guard components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else {
            throw DesktopActivationLinkError("The \(scheme):// link has parts Just Speak to It does not use.")
        }
        return components
    }

    /// Recorder verbs and the routes that only bring the window forward.
    private static func windowRequest(
        route: String, items: [URLQueryItem], scheme: String
    ) throws -> DesktopActivationRequest {
        if let command = DesktopCaptureCommand(rawValue: route) {
            try refuseCaptureOptions(items, allowing: [])
            return .capture(command)
        }
        guard showRoutes.contains(route) else {
            throw DesktopActivationLinkError("Just Speak to It does not recognise the link \(scheme)://\(route).")
        }
        if route == "transcribe", let action = try single("action", in: items) {
            guard let command = DesktopCaptureCommand(rawValue: action.lowercased()) else {
                throw DesktopActivationLinkError("“\(action)” is not a recording action (start, stop or toggle).")
            }
            try refuseCaptureOptions(items, allowing: ["action"])
            return .capture(command)
        }
        guard items.isEmpty else {
            throw DesktopActivationLinkError("The \(scheme)://\(route) link takes no options.")
        }
        return .show
    }

    /// The custom-scheme callback URL a CloudKit API token names, for `scheme`.
    public static func cloudKitSignInURL(scheme: String = ReleaseTrain.current.urlScheme) -> String {
        "\(scheme)://\(cloudKitSignInRoute)"
    }

    private static func signIn(path: String, items: [URLQueryItem]) throws -> DesktopActivationRequest {
        guard path.isEmpty || path == "/" else {
            throw DesktopActivationLinkError("The iCloud sign-in link has an unexpected path.")
        }
        guard let token = try single(webAuthTokenItem, in: items), !token.isEmpty else {
            throw DesktopActivationLinkError("The iCloud sign-in link carries no sign-in token.")
        }
        return .cloudKitSignIn(webAuthToken: token)
    }

    /// The one value of `name`, or `nil` when absent. A repeat is refused, as
    /// the iPhone app refuses repeated capture parameters.
    private static func single(_ name: String, in items: [URLQueryItem]) throws -> String? {
        let matches = items.filter { $0.name.lowercased() == name.lowercased() }
        guard matches.count <= 1 else {
            throw DesktopActivationLinkError("The link gives \(name) more than once.")
        }
        return matches.first.map { $0.value ?? "" }
    }

    private static func refuseCaptureOptions(_ items: [URLQueryItem], allowing allowed: Set<String>) throws {
        let names = items.map { $0.name.lowercased() }.filter { !allowed.contains($0) }
        guard !names.isEmpty else { return }
        if let option = names.first(where: { unsupportedCaptureOptions.contains($0) }) {
            throw DesktopActivationLinkError(
                "The \(option) link option is not available on Windows yet; the recording uses the app's settings."
            )
        }
        throw DesktopActivationLinkError("The link option \(names[0]) is not recognised.")
    }
}

/// The named pipe a running desktop window listens on for forwarded links.
///
/// The first interactive instance owns it. A later launch that carries a link
/// (a browser following `justspeaktoit://…`) forwards the link here and exits,
/// so the running window, which holds the pending sign-in or the recorder,
/// receives it. The name is per user and per release train, like the
/// automation pipe, and the native layer admits only this user's processes at
/// no lower integrity than the app.
public enum DesktopActivationEndpoint {
    /// Overrides the pipe name, for tests and side-by-side instances.
    public static let environmentKey = "SPEAK_ACTIVATION_PIPE"

    public static func pipeName(
        userSID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        train: ReleaseTrain = .current
    ) throws -> String {
        if let override = environment[environmentKey], !override.isEmpty {
            return try AutomationPipeEndpoint.validated(override)
        }
        // Validates the SID exactly as the automation endpoint does.
        _ = try AutomationPipeEndpoint.pipeName(userSID: userSID, environment: [:], train: train)
        return try AutomationPipeEndpoint.validated(
            AutomationPipeEndpoint.localPrefix + "JustSpeakToIt-\(train.supportDirectory)-activation-\(userSID)"
        )
    }
}

/// The bytes a forwarding launch sends: `JSTA`, a version byte, a big-endian
/// UInt32 length and the UTF-8 link. The window answers with one byte.
public enum DesktopActivationFrame {
    public static let magic: [UInt8] = Array("JSTA".utf8)
    public static let version: UInt8 = 1
    public static let headerLength = 9

    public enum Reply: UInt8, Sendable {
        /// The window accepted and is performing the link.
        case accepted = 1
        /// The window understood the link but refused it; it says why itself.
        case refused = 2
        /// The frame was malformed.
        case malformed = 3
    }

    public static func encode(_ link: String) throws -> Data {
        let body = Data(link.utf8)
        guard body.count <= DesktopActivationLink.maximumLength else {
            throw DesktopActivationLinkError("The link is too long to forward.")
        }
        var data = Data(magic)
        data.append(version)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }

    /// The body length a header announces, or `nil` for a malformed header.
    public static func bodyLength(ofHeader header: Data) -> Int? {
        let bytes = [UInt8](header)
        guard bytes.count == headerLength, Array(bytes[0..<4]) == magic, bytes[4] == version else { return nil }
        let length = bytes[5..<9].reduce(0) { ($0 << 8) | Int($1) }
        return length <= DesktopActivationLink.maximumLength ? length : nil
    }

    /// The link a body carries, or `nil` when it is not UTF-8.
    public static func link(fromBody body: Data) -> String? {
        String(data: body, encoding: .utf8)
    }
}
