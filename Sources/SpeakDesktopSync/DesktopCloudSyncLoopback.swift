import Foundation

/// Which account on this computer owns the socket that sent a loopback
/// request, as the host's kernel reports it.
public enum DesktopLoopbackPeer: Sendable, Equatable {
    /// A process running as the same user as this app.
    case currentUser
    /// A process of another account, including system accounts.
    case otherUser
    /// The owner could not be determined. Treated as another account.
    case unknown
}

/// The request line and header fields of one loopback request.
public struct DesktopLoopbackRequestHead: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public var method: String
    /// The request target, such as `/cloudkit-sign-in?…`.
    public var target: String
    /// Header fields in the order received, names as sent.
    public var fields: [Field]

    public init(method: String, target: String, fields: [Field] = []) {
        self.method = method
        self.target = target
        self.fields = fields
    }

    /// Parses the head of a complete HTTP/1.1 request: `nil` when the request
    /// line or a header line is malformed, including obsolete line folding.
    /// Bytes outside ASCII are read as ISO-8859-1, as HTTP defines them, so
    /// they can never match the ASCII values a callback is checked against.
    public init?(parsing request: Data) {
        let end = request.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? request.endIndex
        guard let text = String(bytes: request[request.startIndex..<end], encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
        guard requestLine.count == 3, !requestLine[0].isEmpty, !requestLine[1].isEmpty,
              requestLine[2].hasPrefix("HTTP/") else {
            return nil
        }
        var fields: [Field] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields.append(Field(name: name, value: value))
        }
        self.init(method: String(requestLine[0]), target: String(requestLine[1]), fields: fields)
    }

    /// Every value of the named header field, matched without regard to case.
    public func values(_ name: String) -> [String] {
        let name = name.lowercased()
        return fields.filter { $0.name.lowercased() == name }.map(\.value)
    }
}

/// One HTTP request received on the loopback sign-in callback.
public protocol DesktopLoopbackRequest: Sendable {
    /// The request line and header fields, or `nil` when they are malformed.
    var head: DesktopLoopbackRequestHead? { get }
    /// Whose process sent the request. A host that cannot tell reports
    /// `.unknown`, and the sign-in callback then refuses the request.
    var peer: DesktopLoopbackPeer { get }
    /// Writes a complete response and closes the connection.
    func respond(_ bytes: Data)
}

/// A native listener on this computer's loopback address, open for one
/// sign-in. Nothing outside this computer can connect to it.
public protocol DesktopLoopbackListener: AnyObject, Sendable {
    associatedtype Request: DesktopLoopbackRequest
    /// Waits off the calling thread for one complete request, or returns
    /// `nil` once `timeout` has passed. Cancelling the task throws
    /// `CancellationError`.
    func nextRequest(within timeout: Duration) async throws -> Request?
    /// Stops listening. Only after every `nextRequest` has returned.
    func close()
}

extension DesktopCloudSyncSignIn {
    /// What the listener does with one loopback request during sign-in.
    public enum CallbackDecision: Equatable, Sendable {
        /// The browser's redirect from Apple's sign-in, with its token.
        case accept(webAuthToken: String)
        /// Not the callback, or a callback without a token: answered 404.
        case notFound
        /// A callback this sign-in cannot trust: answered 403, never used.
        case refuse(CallbackRefusal)
    }

    /// Why a request carrying a token was not taken as the callback.
    public enum CallbackRefusal: String, Equatable, Sendable {
        /// Another account's process connected.
        case otherUser
        /// The connecting process's account could not be determined.
        case unverifiedPeer
        /// Not a GET, the only way a browser follows the redirect.
        case method
        /// Addressed to a name other than 127.0.0.1, as a DNS-rebinding page is.
        case host
        /// The browser reports a fetch, frame or subresource rather than a
        /// top-level navigation, or one started from another local page.
        case notTopLevelNavigation
        /// An `Origin` or `Referer` that is not an Apple sign-in page.
        case untrustedInitiator
    }

    /// Decides whether one loopback request completes the sign-in in
    /// progress. Apple appends only `ckWebAuthToken` to the registered
    /// callback and echoes no per-attempt value, so the request itself cannot
    /// be tied to this sign-in. Instead a callback must come from a process of
    /// this user (`peer`), and must look like the top-level browser navigation
    /// Apple's redirect is: a GET to 127.0.0.1 that, where the browser sends
    /// fetch metadata, is a `navigate` to a `document` from another site or
    /// from no page, and whose `Origin` and `Referer`, when present, are HTTPS
    /// pages on apple.com or icloud.com. Absent headers are allowed, since
    /// Apple's referrer policy is not documented and older browsers send no
    /// fetch metadata.
    public static func evaluateCallback(
        _ head: DesktopLoopbackRequestHead?,
        peer: DesktopLoopbackPeer
    ) -> CallbackDecision {
        guard let head, let token = webAuthToken(fromRequestTarget: head.target) else { return .notFound }
        switch peer {
        case .currentUser: break
        case .otherUser: return .refuse(.otherUser)
        case .unknown: return .refuse(.unverifiedPeer)
        }
        guard head.method == "GET" else { return .refuse(.method) }
        let hosts = head.values("Host")
        guard hosts.count == 1, isCallbackHost(hosts[0]) else { return .refuse(.host) }
        guard isTopLevelNavigation(head) else { return .refuse(.notTopLevelNavigation) }
        let initiators = head.values("Origin") + head.values("Referer")
        guard initiators.allSatisfy({ URL(string: $0).map(isTrustedSignInURL) == true }) else {
            return .refuse(.untrustedInitiator)
        }
        return .accept(webAuthToken: token)
    }

    /// `127.0.0.1`, with or without a port, as the registered callback names it.
    private static func isCallbackHost(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.first == Substring(callbackHost) else { return false }
        return parts.count == 1 || UInt16(parts[1]) != nil
    }

    /// Browsers that send fetch metadata (`Sec-Fetch-*`, which pages cannot
    /// forge) mark Apple's redirect as a top-level navigation from another
    /// site, or from no page when the address is opened directly. A fetch,
    /// image or frame request, or a navigation from another page on this
    /// computer's loopback address, is not the callback.
    private static func isTopLevelNavigation(_ head: DesktopLoopbackRequestHead) -> Bool {
        guard head.fields.contains(where: { $0.name.lowercased().hasPrefix("sec-fetch-") }) else { return true }
        func only(_ name: String, in allowed: Set<String>, required: Bool) -> Bool {
            let values = head.values(name).map { $0.lowercased() }
            if values.isEmpty { return !required }
            return values.allSatisfy(allowed.contains)
        }
        return only("Sec-Fetch-Mode", in: ["navigate"], required: true)
            && only("Sec-Fetch-Dest", in: ["document"], required: false)
            && only("Sec-Fetch-Site", in: ["cross-site", "none"], required: false)
    }

    /// Waits for Apple's sign-in to redirect the browser to the callback and
    /// returns its web auth token. A request that is not the callback is
    /// answered with a 404, and one `evaluateCallback` refuses with a 403;
    /// neither ends the sign-in, so a refused request cannot stand in for, or
    /// cut short, the browser's redirect. Waiting goes on until `window` has
    /// passed.
    public static func awaitCallback(
        on listener: some DesktopLoopbackListener,
        within window: Duration
    ) async throws -> String {
        let deadline = ContinuousClock.now + window
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, let request = try await listener.nextRequest(within: remaining) else {
                throw DesktopCloudSyncError.signInTimedOut
            }
            switch evaluateCallback(request.head, peer: request.peer) {
            case .accept(let token):
                request.respond(callbackPage(
                    "Signed in", "You are signed in to iCloud. You can close this tab and return to Just Speak to It."
                ))
                return token
            case .notFound:
                request.respond(callbackPage("Not found", "This address only completes iCloud sign-in.", status: 404))
            case .refuse:
                request.respond(callbackPage(
                    "Not signed in",
                    "This request could not be confirmed as your browser returning from Apple's sign-in, "
                        + "so it was not used. Return to Just Speak to It and sign in again.",
                    status: 403
                ))
            }
        }
    }

    /// A complete, uncached HTTP response with a short page for the browser.
    public static func callbackPage(_ title: String, _ message: String, status: Int = 200) -> Data {
        let body = "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title><p>\(message)</p>"
        let reason = [200: "OK", 403: "Forbidden", 404: "Not Found"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }
}
