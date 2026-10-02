import Foundation
import SpeakSync
import CLinuxSupport

/// AES-256-GCM and PBKDF2-HMAC-SHA256 from the system's OpenSSL (libcrypto),
/// for the existing API-key sync envelope. It must pass the same known-answer
/// vectors as the Apple (CryptoKit) and Windows (CNG) implementations, so this
/// computer opens what a Mac sealed.
public struct LinuxEnvelopeCryptography: SyncEnvelopeCryptography {
    public init() {}

    public func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data {
        guard iterations > 0, keyByteCount > 0 else { throw CloudKitKeySyncError.encryptionFailed }
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

    /// Any nonzero status, including a tag that does not verify, is a failure.
    private static func check(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var error = [CChar](repeating: 0, count: 256)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Int32(-1) }
            return body(base, buffer.count)
        }
        guard result == 0 else { throw CloudKitKeySyncError.encryptionFailed }
    }
}
