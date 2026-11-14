import Foundation

/// Seals a desktop receiver's state file with ChaCha20-Poly1305 under a
/// 32-byte key that lives in the platform credential vault, so the pairing
/// credentials on disk are useless without the user's keyring.
///
/// Layout: one version byte, a random 12-byte nonce, then ciphertext and tag.
package enum TransportSealedState {
    package static let keyByteCount = 32
    private static let version: UInt8 = 1
    private static let nonceByteCount = 12
    private static let associatedData = Array("speak-transport-receiver-state-v1".utf8)

    /// A new random key for `seal(_:key:)`.
    package static func makeKey() -> Data {
        Data(randomBytes(keyByteCount))
    }

    /// The sealed form of `plaintext`, or `nil` when the key is not 32 bytes.
    package static func seal(_ plaintext: Data, key: Data) -> Data? {
        guard key.count == keyByteCount else { return nil }
        let nonce = randomBytes(nonceByteCount)
        let sealed = PortableChaChaPoly.seal(
            Array(plaintext), key: Array(key), nonce: nonce, authenticating: associatedData
        )
        return Data([version] + nonce + sealed)
    }

    /// The plaintext of a sealed blob, or `nil` when it was not sealed under `key`.
    package static func open(_ sealed: Data, key: Data) -> Data? {
        let bytes = Array(sealed)
        guard key.count == keyByteCount, bytes.count > 1 + nonceByteCount, bytes[0] == version else { return nil }
        let nonce = Array(bytes[1...nonceByteCount])
        let frame = Array(bytes[(1 + nonceByteCount)...])
        guard let plaintext = PortableChaChaPoly.open(
            frame, key: Array(key), nonce: nonce, authenticating: associatedData
        ) else { return nil }
        return Data(plaintext)
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
