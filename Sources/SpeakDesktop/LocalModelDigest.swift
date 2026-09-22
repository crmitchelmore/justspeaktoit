import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// One streaming SHA-256 computation backed by an audited platform
/// implementation. A hasher is single-use.
public protocol LocalModelSHA256Hasher: AnyObject {
    func update(_ bytes: UnsafeRawBufferPointer) throws
    /// Returns the lowercase hexadecimal digest.
    func finish() throws -> String
}

/// Creates SHA-256 hashers for verifying pinned artefacts.
///
/// This package deliberately contains no digest implementation of its own:
/// Windows supplies CNG (BCrypt) through its platform adapter and Apple
/// platforms use CryptoKit. Hosts without an audited provider cannot verify
/// downloads and therefore do not offer local models.
public struct LocalModelDigestProvider: Sendable {
    public let name: String
    private let make: @Sendable () throws -> LocalModelSHA256Hasher

    public init(name: String, make: @escaping @Sendable () throws -> LocalModelSHA256Hasher) {
        self.name = name
        self.make = make
    }

    public func makeSHA256() throws -> LocalModelSHA256Hasher {
        try make()
    }

    /// The SHA-256 of `data`, for small in-memory values such as receipts.
    public func sha256(of data: Data) throws -> String {
        let hasher = try makeSHA256()
        try data.withUnsafeBytes { try hasher.update($0) }
        return try hasher.finish()
    }

    /// The platform's audited provider, when this package can reach one.
    public static var platformDefault: LocalModelDigestProvider? {
        #if canImport(CryptoKit)
        return LocalModelDigestProvider(name: "CryptoKit SHA-256") { CryptoKitSHA256Hasher() }
        #else
        return nil
        #endif
    }
}

#if canImport(CryptoKit)
private final class CryptoKitSHA256Hasher: LocalModelSHA256Hasher {
    private var hasher = SHA256()
    private var finished = false

    func update(_ bytes: UnsafeRawBufferPointer) throws {
        guard !finished else { throw LocalModelDigestError.reused }
        hasher.update(bufferPointer: bytes)
    }

    func finish() throws -> String {
        guard !finished else { throw LocalModelDigestError.reused }
        finished = true
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif

public enum LocalModelDigestError: LocalizedError, Equatable {
    case reused
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .reused: return "A digest was used after it finished."
        case .unavailable(let detail): return "The system SHA-256 implementation is unavailable. \(detail)"
        }
    }
}
