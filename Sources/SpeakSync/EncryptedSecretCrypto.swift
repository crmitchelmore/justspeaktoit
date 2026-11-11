import CryptoKit
import Foundation
import SpeakCore

/// CryptoKit implementation of the `EncryptedSecretEnvelope` format.
public enum EncryptedSecretCrypto {
    private static let info = EncryptedSecretEnvelope.keyDerivationInfo
    private static let verifierPlaintext = EncryptedSecretEnvelope.verifierPlaintext
    private static let keyByteCount = EncryptedSecretEnvelope.keyByteCount
    private static let pbkdf2Iterations = EncryptedSecretEnvelope.pbkdf2Iterations
    public static let minimumPassphraseLength = EncryptedSecretEnvelope.minimumPassphraseLength

    /// Derives the local encryption key from a user-owned passphrase and a CloudKit-stored salt.
    /// The passphrase is never sent to CloudKit. CloudKit stores only the random salt and an
    /// AES-GCM verification token, so iCloud private-database access alone cannot read API keys.
    /// A device joins sync by entering the passphrase once; the derived key is then kept only in
    /// that device's Keychain via SecureStorage, not in CloudKit.
    public static func validatePassphrase(_ passphrase: String) throws {
        guard passphrase.count >= minimumPassphraseLength else {
            throw CloudKitKeySyncError.passphraseTooShort(minimumLength: minimumPassphraseLength)
        }
    }

    public static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let derived = pbkdf2SHA256(
            password: Data(passphrase.utf8),
            salt: salt + info,
            iterations: pbkdf2Iterations,
            keyByteCount: keyByteCount
        )
        return SymmetricKey(data: derived)
    }

    static func deriveKeyOffMainActor(passphrase: String, salt: Data) async -> SymmetricKey {
        let keyData = await Task.detached(priority: .userInitiated) {
            deriveKey(passphrase: passphrase, salt: salt).withUnsafeBytes { Data($0) }
        }.value
        return SymmetricKey(data: keyData)
    }

    /// Shared with the QR config transfer via SpeakCore, so both password-based
    /// features stretch their secrets identically.
    static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        keyByteCount: Int
    ) -> Data {
        KeyDerivation.pbkdf2SHA256(
            password: password,
            salt: salt,
            iterations: iterations,
            keyByteCount: keyByteCount
        )
    }

    public static func encryptSecret(
        identifier: String,
        value: String,
        updatedAt: Date,
        key: SymmetricKey,
        isDeleted: Bool = false
    ) throws -> EncryptedSecret {
        let sealedBox = try AES.GCM.seal(Data(value.utf8), using: key)
        return EncryptedSecret(
            identifier: identifier,
            ciphertext: sealedBox.ciphertext,
            nonce: Data(sealedBox.nonce),
            tag: sealedBox.tag,
            updatedAt: updatedAt,
            isDeleted: isDeleted
        )
    }

    public static func decryptSecret(_ secret: EncryptedSecret, key: SymmetricKey) throws -> String {
        let nonce = try AES.GCM.Nonce(data: secret.nonce)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: secret.ciphertext,
            tag: secret.tag
        )
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw CloudKitKeySyncError.encryptionFailed
        }
        return value
    }

    struct VerificationToken {
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    static func makeVerificationToken(key: SymmetricKey) throws -> VerificationToken {
        let sealedBox = try AES.GCM.seal(verifierPlaintext, using: key)
        return VerificationToken(
            nonce: Data(sealedBox.nonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
    }

    static func verifyToken(nonce: Data, ciphertext: Data, tag: Data, key: SymmetricKey) -> Bool {
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: key)
            return plaintext == verifierPlaintext
        } catch {
            return false
        }
    }
}
