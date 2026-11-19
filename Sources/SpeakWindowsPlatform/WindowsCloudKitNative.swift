import Foundation
import SpeakDesktopSync
import SpeakSync
import CWindowsSupport

/// CloudKit Web Services over native WinHTTP, as the rest of the Windows app's
/// networking. Redirects, cookies and caching are off; cancellation closes the
/// native request; errors never contain the URL, whose query holds both tokens.
public struct WinHTTPCloudKitTransport: CloudKitWebServicesHTTPTransport {
    private let timeoutMilliseconds: Int32

    public init(timeout: Duration = .seconds(60)) {
        let seconds = max(1, min(600, timeout.components.seconds))
        timeoutMilliseconds = Int32(seconds * 1000)
    }

    public func send(
        _ request: CloudKitWebServicesHTTPRequest,
        responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse {
        guard let native = NativeHTTPRequest() else {
            throw CloudKitWebServicesTransportError.connectionFailed(retryable: false, description: "WinHTTP")
        }
        let timeout = timeoutMilliseconds
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: native.perform(request, limit: responseLimit, timeout: timeout))
                }
            }
        } onCancel: {
            native.cancel()
        }
    }

    /// Parses WinHTTP's raw CRLF header block into names and values.
    static func headers(fromRaw raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in raw.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return headers
    }
}

/// Owns one native request. Cancellation and destruction are serialised, so a
/// late cancel never reaches a destroyed request.
private final class NativeHTTPRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    init?() {
        guard let handle = jsti_http_request_create() else { return nil }
        self.handle = handle
    }

    func cancel() {
        lock.withLock {
            if let handle { jsti_http_request_cancel(handle) }
        }
    }

    func perform(
        _ request: CloudKitWebServicesHTTPRequest,
        limit: Int,
        timeout: Int32
    ) -> Result<CloudKitWebServicesHTTPResponse, Error> {
        guard let handle = lock.withLock({ handle }) else { return .failure(CancellationError()) }
        defer {
            lock.withLock {
                jsti_http_request_destroy(handle)
                self.handle = nil
            }
        }
        let headerBlock = request.headers.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        var status: Int32 = 0
        var error = [CChar](repeating: 0, count: 512)
        let body = request.body ?? Data()
        let result = body.withUnsafeBytes { bytes in
            jsti_http_request_perform(
                handle, request.method, request.url.absoluteString, headerBlock.isEmpty ? nil : headerBlock,
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, limit, timeout, &status,
                &error, error.count
            )
        }
        let description = String(cString: error)
        switch result {
        case 0:
            var count = 0
            let pointer = jsti_http_request_body(handle, &count)
            let data = pointer.map { Data(bytes: $0, count: count) } ?? Data()
            let raw = String(cString: jsti_http_request_headers(handle))
            return .success(CloudKitWebServicesHTTPResponse(
                statusCode: Int(status), headers: WinHTTPCloudKitTransport.headers(fromRaw: raw), body: data
            ))
        case 1: return .failure(CancellationError())
        case 2: return .failure(CloudKitWebServicesTransportError.responseTooLarge(limit: limit))
        case 3: return .failure(CloudKitWebServicesTransportError.timedOut)
        case 4:
            return .failure(
                CloudKitWebServicesTransportError.connectionFailed(retryable: true, description: description)
            )
        default:
            return .failure(
                CloudKitWebServicesTransportError.connectionFailed(retryable: false, description: description)
            )
        }
    }
}

/// The sign-in callback listener (`DesktopNativeLoopbackListener`) over
/// Winsock, whose peer owner comes from the TCP table's owning process.
public typealias WindowsLoopbackListener = DesktopNativeLoopbackListener

/// A Winsock failure reported by the loopback listener.
public struct WindowsLoopbackError: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

extension DesktopNativeLoopback {
    public static let windows = DesktopNativeLoopback(
        listen: jsti_loopback_listen, accept: jsti_loopback_accept, request: jsti_loopback_request,
        peerOwner: jsti_loopback_peer_owner, respond: jsti_loopback_respond,
        destroyConnection: jsti_loopback_connection_destroy, cancel: jsti_loopback_cancel,
        destroy: jsti_loopback_destroy,
        failure: { WindowsLoopbackError(message: $0) }
    )
}

extension DesktopNativeLoopbackListener {
    public convenience init(port: UInt16 = 0, requestWindow: Duration = .seconds(5)) throws {
        try self.init(native: .windows, port: port, requestWindow: requestWindow)
    }
}

public typealias WindowsEnvelopeCryptography = DesktopNativeEnvelopeCryptography

extension DesktopNativeEnvelopeCryptography {
    /// Windows CNG.
    public init() {
        self.init(
            pbkdf2: jsti_crypto_pbkdf2_sha256, seal: jsti_crypto_aes_gcm_seal,
            open: jsti_crypto_aes_gcm_open, random: jsti_crypto_random
        )
    }
}
