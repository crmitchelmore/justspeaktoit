import CryptoKit
import Foundation
import Security

/// Password-based key derivation shared by the features that turn a
/// user-supplied secret (a sync passphrase, a one-time transfer code) into an
/// AES-GCM key. Kept in SpeakCore so both SpeakSync and the QR config transfer
/// derive keys the same way instead of each hand-rolling PBKDF2.
public enum KeyDerivation {
    /// PBKDF2-HMAC-SHA256 (RFC 2898) built on CryptoKit's HMAC.
    ///
    /// Deliberately iterative and slow: the inputs it protects are short enough
    /// (a passphrase, an 8-character transfer code) that an attacker holding the
    /// ciphertext could otherwise brute-force them offline in seconds.
    public static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        keyByteCount: Int
    ) -> Data {
        let hmacKey = SymmetricKey(data: password)
        let blockCount = Int(ceil(Double(keyByteCount) / Double(SHA256.byteCount)))
        var derived = Data()

        for blockIndex in 1...max(blockCount, 1) {
            var blockSalt = salt
            var bigEndianIndex = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: &bigEndianIndex) { blockSalt.append(contentsOf: $0) }

            var iterationOutput = Data(HMAC<SHA256>.authenticationCode(for: blockSalt, using: hmacKey))
            var block = iterationOutput

            if iterations > 1 {
                for _ in 2...iterations {
                    iterationOutput = Data(HMAC<SHA256>.authenticationCode(for: iterationOutput, using: hmacKey))
                    for index in block.indices {
                        block[index] ^= iterationOutput[index]
                    }
                }
            }

            derived.append(block)
        }

        return Data(derived.prefix(keyByteCount))
    }

    /// Fills `count` bytes from the system CSPRNG, returning nil if the platform
    /// random source fails so callers can surface an error rather than fall back
    /// to a weaker source.
    public static func randomBytes(count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
    }
}
