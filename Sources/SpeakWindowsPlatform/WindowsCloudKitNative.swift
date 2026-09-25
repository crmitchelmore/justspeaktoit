import Foundation
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

/// AES-256-GCM and PBKDF2-HMAC-SHA256 from Windows CNG, for the existing
/// API-key sync envelope. It must pass the same known-answer vectors as the
/// Apple implementation.
public struct WindowsEnvelopeCryptography: SyncEnvelopeCryptography {
    public init() {}

    public func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data {
        var key = [UInt8](repeating: 0, count: keyByteCount)
        try Self.check { error, capacity in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    jsti_crypto_pbkdf2_sha256(
                        passwordBytes.bindMemory(to: UInt8.self).baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        UInt64(iterations), &key, key.count, error, capacity
                    )
                }
            }
        }
        return Data(key)
    }

    public func sealAESGCM(_ plaintext: Data, key: Data) throws -> SealedEnvelopePayload {
        var nonce = [UInt8](repeating: 0, count: 12)
        var tag = [UInt8](repeating: 0, count: 16)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        try Self.check { error, capacity in
            key.withUnsafeBytes { keyBytes in
                plaintext.withUnsafeBytes { plainBytes in
                    jsti_crypto_aes_gcm_seal(
                        keyBytes.bindMemory(to: UInt8.self).baseAddress, key.count,
                        plainBytes.bindMemory(to: UInt8.self).baseAddress, plaintext.count,
                        &nonce, &ciphertext, &tag, error, capacity
                    )
                }
            }
        }
        return SealedEnvelopePayload(nonce: Data(nonce), ciphertext: Data(ciphertext), tag: Data(tag))
    }

    public func openAESGCM(_ sealed: SealedEnvelopePayload, key: Data) throws -> Data {
        guard sealed.nonce.count == 12, sealed.tag.count == 16 else { throw CloudKitKeySyncError.encryptionFailed }
        var plaintext = [UInt8](repeating: 0, count: sealed.ciphertext.count)
        defer { for index in plaintext.indices { plaintext[index] = 0 } }
        try Self.check { error, capacity in
            key.withUnsafeBytes { keyBytes in
                sealed.nonce.withUnsafeBytes { nonce in
                    sealed.ciphertext.withUnsafeBytes { cipher in
                        sealed.tag.withUnsafeBytes { tag in
                            jsti_crypto_aes_gcm_open(
                                keyBytes.bindMemory(to: UInt8.self).baseAddress, key.count,
                                nonce.bindMemory(to: UInt8.self).baseAddress,
                                cipher.bindMemory(to: UInt8.self).baseAddress, sealed.ciphertext.count,
                                tag.bindMemory(to: UInt8.self).baseAddress, &plaintext, error, capacity
                            )
                        }
                    }
                }
            }
        }
        return Data(plaintext)
    }

    public func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        try Self.check { error, capacity in jsti_crypto_random(&bytes, bytes.count, error, capacity) }
        return Data(bytes)
    }

    private static func check(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var error = [CChar](repeating: 0, count: 256)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Int32(-1) }
            return body(base, buffer.count)
        }
        guard result == 0 else { throw CloudKitKeySyncError.encryptionFailed }
    }
}

/// A 127.0.0.1-only HTTP listener: the Apple ID sign-in callback, and the
/// loopback fake server in tests.
public final class WindowsLoopbackListener: @unchecked Sendable {
    public struct Connection: @unchecked Sendable {
        fileprivate let handle: OpaquePointer

        public var request: Data {
            var count = 0
            guard let bytes = jsti_loopback_request(handle, &count) else { return Data() }
            return Data(bytes: bytes, count: count)
        }

        /// The request target of the first line, such as `/cloudkit-sign-in?…`.
        public var target: String? {
            let head = String(bytes: request.prefix(8 * 1024), encoding: .utf8) ?? ""
            let parts = head.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
            return parts.count == 3 ? String(parts[1]) : nil
        }

        /// Whether a process of this user opened the connection, from the TCP
        /// table's owning process: `false` for another account, `nil` when
        /// that cannot be determined. Read before `respond`.
        public var peerIsCurrentUser: Bool? {
            switch jsti_loopback_peer_owner(handle) {
            case 0: return true
            case 1: return false
            default: return nil
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

    public enum Failure: Error, Equatable {
        case timedOut
        case native(String)
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?
    public let port: UInt16

    public init(port: UInt16 = 0) throws {
        var bound: UInt16 = 0
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = jsti_loopback_listen(port, &bound, &error, error.count) else {
            throw Failure.native(String(cString: error))
        }
        self.handle = handle
        self.port = bound
    }

    /// Waits off the calling thread for one complete request.
    public func accept(timeout: Duration) async throws -> Connection {
        let milliseconds = Int32(max(0, min(Int64(Int32.max), timeout.components.seconds * 1000)))
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

    private func acceptNow(_ milliseconds: Int32) -> Result<Connection, Error> {
        guard let handle = lock.withLock({ handle }) else { return .failure(CancellationError()) }
        var connection: OpaquePointer?
        var error = [CChar](repeating: 0, count: 512)
        switch jsti_loopback_accept(handle, milliseconds, &connection, &error, error.count) {
        case 0:
            guard let connection else { return .failure(Failure.native("No connection.")) }
            return .success(Connection(handle: connection))
        case 1: return .failure(Failure.timedOut)
        case 3: return .failure(CancellationError())
        default: return .failure(Failure.native(String(cString: error)))
        }
    }

    public func cancel() {
        lock.withLock { if let handle { jsti_loopback_cancel(handle) } }
    }

    /// Only after every `accept` has returned.
    public func close() {
        lock.withLock {
            if let handle { jsti_loopback_destroy(handle) }
            handle = nil
        }
    }

    deinit { close() }
}
