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

/// The sign-in callback listener (`DesktopNativeLoopbackListener`) over
/// LinuxCloudSync.c, whose peer owner comes from /proc/net/tcp and tcp6.
public typealias LinuxLoopbackListener = DesktopNativeLoopbackListener

extension DesktopNativeLoopback {
    public static let linux = DesktopNativeLoopback(
        listen: jsti_loopback_listen, accept: jsti_loopback_accept, request: jsti_loopback_request,
        peerOwner: jsti_loopback_peer_owner, respond: jsti_loopback_respond,
        destroyConnection: jsti_loopback_connection_destroy, cancel: jsti_loopback_cancel,
        destroy: jsti_loopback_destroy,
        failure: { LinuxNativeError(message: $0) }
    )
}

extension DesktopNativeLoopbackListener {
    public convenience init(port: UInt16 = 0, requestWindow: Duration = .seconds(5)) throws {
        try self.init(native: .linux, port: port, requestWindow: requestWindow)
    }
}
