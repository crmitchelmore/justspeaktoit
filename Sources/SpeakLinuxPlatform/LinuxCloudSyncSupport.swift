import Foundation
#if canImport(Glibc)
import Glibc
#endif
import CLinuxSupport
import SpeakDesktopSync
import SpeakSync

/// AES-256-GCM, PBKDF2-HMAC-SHA256 and random bytes from GnuTLS for the
/// existing API-key sync envelope. It must pass the same known-answer vectors
/// as the Apple (CryptoKit) and Windows (CNG) implementations.
public struct LinuxEnvelopeCryptography: SyncEnvelopeCryptography {
    public init() {}

    public func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data {
        var key = [UInt8](repeating: 0, count: keyByteCount)
        try Self.check { error, capacity in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    jsti_crypto_pbkdf2_sha256(
                        passwordBytes.bindMemory(to: UInt8.self).baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        UInt64(max(0, iterations)), &key, key.count, error, capacity
                    )
                }
            }
        }
        return Data(key)
    }

    public func sealAESGCM(_ plaintext: Data, key: Data) throws -> SealedEnvelopePayload {
        var nonce = [UInt8](repeating: 0, count: EncryptedSecretEnvelope.nonceByteCount)
        var tag = [UInt8](repeating: 0, count: EncryptedSecretEnvelope.tagByteCount)
        var ciphertext = [UInt8](repeating: 0, count: max(plaintext.count, 1))
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
        return SealedEnvelopePayload(
            nonce: Data(nonce), ciphertext: Data(ciphertext.prefix(plaintext.count)), tag: Data(tag)
        )
    }

    public func openAESGCM(_ sealed: SealedEnvelopePayload, key: Data) throws -> Data {
        guard sealed.nonce.count == EncryptedSecretEnvelope.nonceByteCount,
              sealed.tag.count == EncryptedSecretEnvelope.tagByteCount else {
            throw CloudKitKeySyncError.encryptionFailed
        }
        var plaintext = [UInt8](repeating: 0, count: max(sealed.ciphertext.count, 1))
        defer { for index in plaintext.indices { plaintext[index] = 0 } }
        do {
            try Self.check { error, capacity in
                key.withUnsafeBytes { keyBytes in
                    sealed.nonce.withUnsafeBytes { nonceBytes in
                        sealed.ciphertext.withUnsafeBytes { cipherBytes in
                            sealed.tag.withUnsafeBytes { tagBytes in
                                jsti_crypto_aes_gcm_open(
                                    keyBytes.bindMemory(to: UInt8.self).baseAddress, key.count,
                                    nonceBytes.bindMemory(to: UInt8.self).baseAddress,
                                    cipherBytes.bindMemory(to: UInt8.self).baseAddress, sealed.ciphertext.count,
                                    tagBytes.bindMemory(to: UInt8.self).baseAddress, &plaintext, error, capacity
                                )
                            }
                        }
                    }
                }
            }
        } catch {
            throw CloudKitKeySyncError.encryptionFailed
        }
        return Data(plaintext.prefix(sealed.ciphertext.count))
    }

    public func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        do {
            try Self.check { jsti_crypto_random(&bytes, bytes.count, $0, $1) }
        } catch {
            throw CloudKitKeySyncError.randomGenerationFailed
        }
        return Data(bytes)
    }

    private static func check(_ action: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        try LinuxNative.call(action)
    }
}

/// The Secret Service keyring as the sync credential vault: the rotating web
/// auth token, the derived API-key sync key and imported provider keys, each
/// under its canonical identifier.
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

/// A one-request-at-a-time HTTP listener on 127.0.0.1 for Apple's sign-in
/// redirect (`DesktopCloudSyncSignIn.callbackURL`), open only during sign-in.
/// It never binds another interface, reads at most `maximumRequestBytes` of a
/// request head, and answers each connection once before closing it.
public final class LinuxLoopbackListener: @unchecked Sendable {
    /// The sign-in callback is a bodiless GET; tests serving a fake CloudKit
    /// over this listener raise the cap for request bodies.
    public let maximumRequestBytes: Int

    public enum Failure: Error, Equatable, LocalizedError {
        case timedOut
        case native(String)

        public var errorDescription: String? {
            switch self {
            case .timedOut: return "The sign-in page did not return in time. Try signing in again."
            case .native(let message): return message
            }
        }
    }

    /// One accepted request, answered by `respond`.
    public struct Connection: @unchecked Sendable {
        fileprivate let socket: Int32
        public let request: Data

        /// The request target of the first line, such as `/cloudkit-sign-in?…`.
        public var target: String? {
            let head = String(bytes: request.prefix(8 * 1024), encoding: .utf8) ?? ""
            let parts = head.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
            return parts.count == 3 ? String(parts[1]) : nil
        }

        /// Writes a complete response and closes the connection.
        public func respond(_ bytes: Data) {
            bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let sent = Glibc.send(
                        socket, raw.baseAddress!.advanced(by: offset), raw.count - offset, Int32(MSG_NOSIGNAL)
                    )
                    if sent <= 0 { break }
                    offset += sent
                }
            }
            Glibc.shutdown(socket, Int32(SHUT_RDWR))
            Glibc.close(socket)
        }
    }

    private let lock = NSLock()
    private var listening: Int32
    private var wake: [Int32] = [-1, -1]
    public let port: UInt16

    /// Binds 127.0.0.1:`port` (0 picks a free port, for tests).
    public init(port: UInt16 = 0, maximumRequestBytes: Int = 16 * 1024) throws {
        self.maximumRequestBytes = maximumRequestBytes
        let descriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard descriptor >= 0 else { throw Failure.native(Self.describe("create the sign-in listener")) }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Glibc.listen(descriptor, 4) == 0 else {
            let reason = errno == EADDRINUSE
                ? "Another program is using port \(port), which iCloud sign-in needs. Close it and try again."
                : Self.describe("listen for the sign-in page")
            Glibc.close(descriptor)
            throw Failure.native(reason)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        var pipeEnds: [Int32] = [-1, -1]
        guard Glibc.pipe(&pipeEnds) == 0 else {
            Glibc.close(descriptor)
            throw Failure.native(Self.describe("prepare the sign-in listener"))
        }
        for end in pipeEnds {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
        }
        listening = descriptor
        wake = pipeEnds
        self.port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { close() }

    /// Waits off the calling thread for one complete request head.
    public func accept(timeout: Duration) async throws -> Connection {
        let milliseconds = Int32(max(0, min(Int64(Int32.max), timeout.components.seconds * 1000
            + timeout.components.attoseconds / 1_000_000_000_000_000)))
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

    /// Wakes every pending and later `accept`, which then throw `CancellationError`.
    public func cancel() {
        lock.withLock {
            guard wake[1] >= 0 else { return }
            var byte: UInt8 = 1
            _ = Glibc.write(wake[1], &byte, 1)
        }
    }

    /// Only after every `accept` has returned.
    public func close() {
        lock.withLock {
            if listening >= 0 { Glibc.close(listening) }
            for end in wake where end >= 0 { Glibc.close(end) }
            listening = -1
            wake = [-1, -1]
        }
    }

    private func acceptNow(_ milliseconds: Int32) -> Result<Connection, Error> {
        let (descriptor, cancelEnd) = lock.withLock { (listening, wake[0]) }
        guard descriptor >= 0 else { return .failure(CancellationError()) }
        var fds = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: cancelEnd, events: Int16(POLLIN), revents: 0)]
        let ready = poll(&fds, nfds_t(fds.count), milliseconds)
        if ready == 0 { return .failure(Failure.timedOut) }
        if ready < 0 { return .failure(Failure.native(Self.describe("wait for the sign-in page"))) }
        if fds[1].revents != 0 { return .failure(CancellationError()) }
        let client = Glibc.accept(descriptor, nil, nil)
        guard client >= 0 else { return .failure(Failure.native(Self.describe("accept the sign-in page"))) }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        return .success(Connection(
            socket: client, request: Self.readRequest(client, cancel: cancelEnd, limit: maximumRequestBytes)
        ))
    }

    /// Reads the head and any `Content-Length` body, stopping at the size
    /// cap, five seconds of silence or cancellation.
    private static func readRequest(_ socket: Int32, cancel: Int32, limit: Int) -> Data {
        var data = Data()
        var expected: Int?
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            if let expected, data.count >= expected { break }
            var fds = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: cancel, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, nfds_t(fds.count), 5_000) > 0, fds[1].revents == 0 else { break }
            let count = Glibc.recv(socket, &buffer, min(buffer.count, limit - data.count), 0)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
            if expected == nil, let end = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = (String(bytes: data[..<end.lowerBound], encoding: .utf8) ?? "").lowercased()
                let length = head.components(separatedBy: "\r\n").lazy
                    .compactMap { line -> Int? in
                        guard line.hasPrefix("content-length:") else { return nil }
                        return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                    }.first ?? 0
                expected = end.upperBound + max(0, length)
            }
        }
        return data
    }

    private static func describe(_ action: String) -> String {
        "Could not \(action): \(String(cString: strerror(errno)))."
    }
}

/// The browser half of iCloud sign-in shared by the app and its tests.
public enum LinuxCloudSyncSignIn {
    /// Answers requests on `listener` until one carries the web auth token,
    /// which it returns; anything else gets a 404. Throws `timedOut` once
    /// `window` has passed without a token.
    public static func awaitCallback(on listener: LinuxLoopbackListener, window: Duration) async throws -> String {
        let deadline = ContinuousClock.now + window
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw LinuxLoopbackListener.Failure.timedOut }
            let connection = try await listener.accept(timeout: remaining)
            if let target = connection.target,
               let token = DesktopCloudSyncSignIn.webAuthToken(fromRequestTarget: target) {
                connection.respond(callbackPage(
                    "Signed in", "You are signed in to iCloud. You can close this tab and return to Just Speak to It."
                ))
                return token
            }
            connection.respond(callbackPage("Not found", "This address only completes iCloud sign-in.", status: 404))
        }
    }

    static func callbackPage(_ title: String, _ message: String, status: Int = 200) -> Data {
        let body = "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title><p>\(message)</p>"
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }
}
