import Foundation
import SpeakSync

/// AES-256-GCM and PBKDF2-HMAC-SHA256 for the API-key sync envelope through a
/// desktop adapter's C ABI: Windows CNG or Linux OpenSSL (libcrypto). Every
/// adapter must pass the same known-answer vectors as the Apple (CryptoKit)
/// implementation, so this computer opens what a Mac sealed. It holds only C
/// function references, so sharing it is safe.
public struct DesktopNativeEnvelopeCryptography: SyncEnvelopeCryptography, @unchecked Sendable {
    public typealias Bytes = UnsafePointer<UInt8>?
    public typealias Output = UnsafeMutablePointer<UInt8>?
    public typealias ErrorBuffer = UnsafeMutablePointer<CChar>?

    /// password, count, salt, count, iterations, key, count, error, capacity.
    public let pbkdf2: (Bytes, Int, Bytes, Int, UInt64, Output, Int, ErrorBuffer, Int) -> Int32
    /// key, count, plaintext, count, nonce12, ciphertext, tag16, error, capacity.
    public let seal: (Bytes, Int, Bytes, Int, Output, Output, Output, ErrorBuffer, Int) -> Int32
    /// key, count, nonce12, ciphertext, count, tag16, plaintext, error, capacity.
    public let open: (Bytes, Int, Bytes, Bytes, Int, Bytes, Output, ErrorBuffer, Int) -> Int32
    public let random: (Output, Int, ErrorBuffer, Int) -> Int32

    public init(
        pbkdf2: @escaping (Bytes, Int, Bytes, Int, UInt64, Output, Int, ErrorBuffer, Int) -> Int32,
        seal: @escaping (Bytes, Int, Bytes, Int, Output, Output, Output, ErrorBuffer, Int) -> Int32,
        open: @escaping (Bytes, Int, Bytes, Bytes, Int, Bytes, Output, ErrorBuffer, Int) -> Int32,
        random: @escaping (Output, Int, ErrorBuffer, Int) -> Int32
    ) {
        self.pbkdf2 = pbkdf2
        self.seal = seal
        self.open = open
        self.random = random
    }

    public func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data {
        guard iterations > 0, keyByteCount > 0 else { throw CloudKitKeySyncError.encryptionFailed }
        var key = [UInt8](repeating: 0, count: keyByteCount)
        try Self.check { error, capacity in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    pbkdf2(
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
                    seal(
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
                            open(
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
        try Self.check { error, capacity in random(&bytes, bytes.count, error, capacity) }
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
