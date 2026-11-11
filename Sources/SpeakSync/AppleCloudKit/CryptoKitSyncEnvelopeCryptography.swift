import CryptoKit
import Foundation
import Security

/// CryptoKit primitives behind the portable envelope seam. These are the same
/// calls `EncryptedSecretCrypto` makes, so the seam is checked against the
/// production Apple implementation rather than a second copy of it.
struct CryptoKitSyncEnvelopeCryptography: SyncEnvelopeCryptography {
    func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) -> Data {
        EncryptedSecretCrypto.pbkdf2SHA256(
            password: password,
            salt: salt,
            iterations: iterations,
            keyByteCount: keyByteCount
        )
    }

    func sealAESGCM(_ plaintext: Data, key: Data) throws -> SealedEnvelopePayload {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        return SealedEnvelopePayload(nonce: Data(box.nonce), ciphertext: box.ciphertext, tag: box.tag)
    }

    func openAESGCM(_ sealed: SealedEnvelopePayload, key: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw CloudKitKeySyncError.randomGenerationFailed
        }
        return Data(bytes)
    }
}
