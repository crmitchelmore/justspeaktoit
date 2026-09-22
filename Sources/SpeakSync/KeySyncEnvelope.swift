import Foundation

public struct EncryptedSecret: Equatable, Sendable {
    public let identifier: String
    public let ciphertext: Data
    public let nonce: Data
    public let tag: Data
    public let updatedAt: Date
    public let isDeleted: Bool

    public init(
        identifier: String,
        ciphertext: Data,
        nonce: Data,
        tag: Data,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.identifier = identifier
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.tag = tag
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

public enum CloudKitKeySyncError: LocalizedError, Equatable {
    case cloudUnavailable
    case missingPassphrase
    case incorrectPassphrase
    case encryptionFailed
    case malformedRecord
    case invalidChangeToken
    case passphraseTooShort(minimumLength: Int)
    case randomGenerationFailed
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .cloudUnavailable:
            return "CloudKit is unavailable for this build, device, or iCloud account."
        case .missingPassphrase:
            return "Enter the API-key sync passphrase to join this device."
        case .incorrectPassphrase:
            return "The API-key sync passphrase is incorrect."
        case .encryptionFailed:
            return "Failed to encrypt or decrypt the API key."
        case .malformedRecord:
            return "CloudKit returned an invalid encrypted key record."
        case .invalidChangeToken:
            return "CloudKit returned an invalid synchronization token."
        case .passphraseTooShort(let minimumLength):
            return "Use an API-key sync passphrase with at least \(minimumLength) characters."
        case .randomGenerationFailed:
            return "Failed to generate secure random bytes for API-key sync."
        case .notConfigured:
            return "API-key sync has not finished configuring secure storage."
        }
    }
}

/// The random salt and passphrase verifier stored once per iCloud account.
public struct KeySyncMetadata: Equatable, Sendable {
    public let salt: Data
    public let verifierNonce: Data
    public let verifierCiphertext: Data
    public let verifierTag: Data

    public init(salt: Data, verifierNonce: Data, verifierCiphertext: Data, verifierTag: Data) {
        self.salt = salt
        self.verifierNonce = verifierNonce
        self.verifierCiphertext = verifierCiphertext
        self.verifierTag = verifierTag
    }
}

/// The parts of one AES-GCM sealed box, exactly as the records store them.
public struct SealedEnvelopePayload: Equatable, Sendable {
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    public init(nonce: Data, ciphertext: Data, tag: Data) {
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

/// The primitives API-key sync needs from a platform cryptography library.
///
/// The envelope's parameters live in `EncryptedSecretEnvelope`; a conformer only
/// supplies audited primitives — CryptoKit on Apple platforms, and a native
/// CNG (BCrypt) adapter on Windows, which is not implemented yet. Never
/// substitute a hand-written cipher or key-derivation function.
public protocol SyncEnvelopeCryptography: Sendable {
    /// PBKDF2 with HMAC-SHA256 (RFC 8018).
    func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data
    /// AES-256-GCM with a fresh random 96-bit nonce, no associated data and a
    /// 128-bit tag. The ciphertext excludes the tag.
    func sealAESGCM(_ plaintext: Data, key: Data) throws -> SealedEnvelopePayload
    /// Authenticated AES-256-GCM decryption; throws on any key, nonce or tag mismatch.
    func openAESGCM(_ sealed: SealedEnvelopePayload, key: Data) throws -> Data
    /// Bytes from the platform's cryptographically secure generator.
    func randomBytes(count: Int) throws -> Data
}

/// The existing API-key sync envelope, `justspeaktoit.api-key-sync.v1`.
///
/// A device derives a 256-bit key from the user's passphrase with
/// PBKDF2-HMAC-SHA256 over `salt + info` (210,000 iterations). The random
/// 32-byte salt is stored in CloudKit with an AES-GCM verifier of a fixed
/// plaintext, so a wrong passphrase is rejected before any key is decrypted.
/// Each secret is sealed separately with AES-256-GCM. Neither the passphrase
/// nor the derived key leaves the device. Every parameter here is part of the
/// stored format that existing Apple clients read.
public struct EncryptedSecretEnvelope: Sendable {
    public static let keyDerivationInfo = Data("justspeaktoit.api-key-sync.v1".utf8)
    public static let verifierPlaintext = Data("justspeaktoit.api-key-sync.verifier.v1".utf8)
    public static let keyByteCount = 32
    public static let pbkdf2Iterations = 210_000
    public static let minimumPassphraseLength = 12
    public static let saltByteCount = 32
    public static let nonceByteCount = 12
    public static let tagByteCount = 16

    private let cryptography: any SyncEnvelopeCryptography
    private let iterations: Int

    public init(cryptography: any SyncEnvelopeCryptography) {
        self.init(cryptography: cryptography, iterations: Self.pbkdf2Iterations)
    }

    /// Tests only: a reduced iteration count keeps primitive checks fast.
    init(cryptography: any SyncEnvelopeCryptography, iterations: Int) {
        self.cryptography = cryptography
        self.iterations = iterations
    }

    /// Trims and checks a typed passphrase exactly as enabling key sync does.
    public static func normalizedPassphrase(_ passphrase: String) throws -> String {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudKitKeySyncError.missingPassphrase }
        guard trimmed.count >= minimumPassphraseLength else {
            throw CloudKitKeySyncError.passphraseTooShort(minimumLength: minimumPassphraseLength)
        }
        return trimmed
    }

    public func deriveKey(passphrase: String, salt: Data) throws -> Data {
        let key: Data
        do {
            key = try cryptography.pbkdf2SHA256(
                password: Data(passphrase.utf8),
                salt: salt + Self.keyDerivationInfo,
                iterations: iterations,
                keyByteCount: Self.keyByteCount
            )
        } catch {
            throw CloudKitKeySyncError.encryptionFailed
        }
        guard key.count == Self.keyByteCount else { throw CloudKitKeySyncError.encryptionFailed }
        return key
    }

    /// Creates the salt and verifier for an account that has none yet.
    public func makeMetadata(passphrase: String) throws -> (metadata: KeySyncMetadata, key: Data) {
        let salt = try randomSalt()
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let verifier = try seal(Self.verifierPlaintext, key: key)
        let metadata = KeySyncMetadata(
            salt: salt,
            verifierNonce: verifier.nonce,
            verifierCiphertext: verifier.ciphertext,
            verifierTag: verifier.tag
        )
        return (metadata, key)
    }

    /// Derives the key for existing metadata, rejecting a wrong passphrase.
    public func unlock(_ metadata: KeySyncMetadata, passphrase: String) throws -> Data {
        let key = try deriveKey(passphrase: passphrase, salt: metadata.salt)
        guard verifies(metadata, key: key) else { throw CloudKitKeySyncError.incorrectPassphrase }
        return key
    }

    public func verifies(_ metadata: KeySyncMetadata, key: Data) -> Bool {
        let sealed = SealedEnvelopePayload(
            nonce: metadata.verifierNonce,
            ciphertext: metadata.verifierCiphertext,
            tag: metadata.verifierTag
        )
        guard let plaintext = try? open(sealed, key: key) else { return false }
        return plaintext == Self.verifierPlaintext
    }

    public func seal(
        identifier: String,
        value: String,
        updatedAt: Date,
        key: Data,
        isDeleted: Bool = false
    ) throws -> EncryptedSecret {
        let sealed = try seal(Data(value.utf8), key: key)
        return EncryptedSecret(
            identifier: identifier,
            ciphertext: sealed.ciphertext,
            nonce: sealed.nonce,
            tag: sealed.tag,
            updatedAt: updatedAt,
            isDeleted: isDeleted
        )
    }

    public func open(_ secret: EncryptedSecret, key: Data) throws -> String {
        let sealed = SealedEnvelopePayload(nonce: secret.nonce, ciphertext: secret.ciphertext, tag: secret.tag)
        guard let value = String(data: try open(sealed, key: key), encoding: .utf8) else {
            throw CloudKitKeySyncError.encryptionFailed
        }
        return value
    }

    private func seal(_ plaintext: Data, key: Data) throws -> SealedEnvelopePayload {
        guard key.count == Self.keyByteCount else { throw CloudKitKeySyncError.encryptionFailed }
        let sealed: SealedEnvelopePayload
        do {
            sealed = try cryptography.sealAESGCM(plaintext, key: key)
        } catch {
            throw CloudKitKeySyncError.encryptionFailed
        }
        // A provider that appended the tag to the ciphertext, or used another
        // nonce size, would write records no other client can open.
        guard sealed.nonce.count == Self.nonceByteCount,
              sealed.tag.count == Self.tagByteCount,
              sealed.ciphertext.count == plaintext.count else {
            throw CloudKitKeySyncError.encryptionFailed
        }
        return sealed
    }

    private func open(_ sealed: SealedEnvelopePayload, key: Data) throws -> Data {
        guard key.count == Self.keyByteCount,
              sealed.nonce.count == Self.nonceByteCount,
              sealed.tag.count == Self.tagByteCount else {
            throw CloudKitKeySyncError.encryptionFailed
        }
        do {
            return try cryptography.openAESGCM(sealed, key: key)
        } catch {
            throw CloudKitKeySyncError.encryptionFailed
        }
    }

    private func randomSalt() throws -> Data {
        let salt: Data
        do {
            salt = try cryptography.randomBytes(count: Self.saltByteCount)
        } catch {
            throw CloudKitKeySyncError.randomGenerationFailed
        }
        guard salt.count == Self.saltByteCount else { throw CloudKitKeySyncError.randomGenerationFailed }
        return salt
    }
}
