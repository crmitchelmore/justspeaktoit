import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakDesktopSync
import SpeakSync
import CLinuxSupport

/// CloudKit Web Services over FoundationNetworking's URLSession, as the rest
/// of the Linux app's batch HTTP. The shared bounded exchange refuses
/// redirects and caching, caps the body and cancels the request with its
/// task; this session also keeps no cookies, cache or credentials. Plain HTTP
/// is refused except to this computer's loopback address (fake servers in
/// tests). Errors never contain the URL, whose query holds both tokens.
public struct LinuxCloudKitTransport: CloudKitWebServicesHTTPTransport {
    private let transport: URLSessionCloudKitWebServicesTransport

    public init(timeout: Duration = .seconds(60)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        transport = URLSessionCloudKitWebServicesTransport(
            session: URLSession(configuration: configuration), deadline: timeout
        )
    }

    public func send(
        _ request: CloudKitWebServicesHTTPRequest,
        responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse {
        guard Self.isAllowed(request.url) else {
            throw CloudKitWebServicesTransportError.connectionFailed(
                retryable: false, description: "Only HTTPS requests are allowed."
            )
        }
        return try await transport.send(request, responseLimit: responseLimit)
    }

    static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }
}

/// The Secret Service keyring as the sync credential vault: the rotating web
/// auth token, the key derived from the API-key sync passphrase and imported
/// provider keys, under the same identifiers as keys typed in Settings. Each
/// value is at most 8 KiB.
public struct LinuxCredentialVault: DesktopCredentialVault {
    public init() {}

    public func readCredential(_ name: String) throws -> String? {
        let value = try LinuxCredentialStore.read(name: name)
        return value.isEmpty ? nil : value
    }

    public func writeCredential(_ value: String, name: String) throws {
        try LinuxCredentialStore.save(value, name: name)
    }

    public func deleteCredential(_ name: String) throws {
        try LinuxCredentialStore.save("", name: name)
    }
}

public enum LinuxSignInPage {
    /// Opens Apple's sign-in page in the default browser (the OpenURI portal
    /// inside Flatpak). Anything but an https page on apple.com or icloud.com
    /// is refused.
    public static func open(_ url: URL) throws {
        try url.absoluteString.withCString { url in try LinuxNative.call { jsti_open_sign_in_page(url, $0, $1) } }
    }
}

/// A 127.0.0.1-only HTTP listener: the Apple ID sign-in callback, and the
/// loopback fake server in tests. A connection that sends no complete request
/// within `requestWindow` is dropped, so an idle browser preconnection cannot
/// hold the callback. Each request reports which user's process sent it, so
/// the callback can refuse other accounts on this computer.
public final class LinuxLoopbackListener: DesktopLoopbackListener, @unchecked Sendable {
    public struct Connection: DesktopLoopbackRequest, @unchecked Sendable {
        fileprivate let handle: OpaquePointer

        public var request: Data {
            var count = 0
            guard let bytes = jsti_loopback_request(handle, &count) else { return Data() }
            return Data(bytes: bytes, count: count)
        }

        /// The request line and header fields.
        public var head: DesktopLoopbackRequestHead? { DesktopLoopbackRequestHead(parsing: request) }

        /// Whose process connected, from the kernel's TCP tables. Read while
        /// the connection is open, before `respond`.
        public var peer: DesktopLoopbackPeer {
            switch jsti_loopback_peer_owner(handle) {
            case 0: return .currentUser
            case 1: return .otherUser
            default: return .unknown
            }
        }

        /// Writes a complete response and closes the connection.
        public func respond(_ bytes: Data) {
            _ = bytes.withUnsafeBytes {
                jsti_loopback_respond(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
            }
            jsti_loopback_connection_destroy(handle)
        }
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?
    public let port: UInt16

    public init(port: UInt16 = 0, requestWindow: Duration = .seconds(5)) throws {
        var bound: UInt16 = 0
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = jsti_loopback_listen(
            port, Self.milliseconds(requestWindow), &bound, &error, error.count
        ) else {
            throw LinuxNativeError(message: String(cString: error))
        }
        self.handle = handle
        self.port = bound
    }

    /// Waits off the calling thread for one complete request.
    public func nextRequest(within timeout: Duration) async throws -> Connection? {
        let milliseconds = Self.milliseconds(timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: self.acceptNow(milliseconds))
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func acceptNow(_ milliseconds: Int32) -> Result<Connection?, Error> {
        guard let handle = lock.withLock({ handle }) else { return .failure(CancellationError()) }
        var connection: OpaquePointer?
        var error = [CChar](repeating: 0, count: 512)
        switch jsti_loopback_accept(handle, milliseconds, &connection, &error, error.count) {
        case 0:
            guard let connection else { return .failure(LinuxNativeError(message: "No connection.")) }
            return .success(Connection(handle: connection))
        case 1: return .success(nil)
        case 3: return .failure(CancellationError())
        default: return .failure(LinuxNativeError(message: String(cString: error)))
        }
    }

    /// Ends a waiting `nextRequest` with `CancellationError`, and every later one.
    public func cancel() {
        lock.withLock { if let handle { jsti_loopback_cancel(handle) } }
    }

    /// Stops listening. Only after every `nextRequest` has returned.
    public func close() {
        lock.withLock {
            if let handle { jsti_loopback_destroy(handle) }
            handle = nil
        }
    }

    deinit { close() }

    private static func milliseconds(_ duration: Duration) -> Int32 {
        let (seconds, attoseconds) = duration.components
        let total = seconds.multipliedReportingOverflow(by: 1_000)
        guard !total.overflow else { return seconds < 0 ? 0 : Int32.max }
        return Int32(clamping: max(0, total.partialValue + attoseconds / 1_000_000_000_000_000))
    }
}
