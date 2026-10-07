import Foundation
import XCTest
#if canImport(CryptoKit) && canImport(CommonCrypto)
import CommonCrypto
import CryptoKit
import Security
#endif

@testable import SpeakSync

/// Envelope rules that hold for any conforming crypto provider. The fake below
/// is deliberately not cryptography: it only lets the control flow be checked
/// on every platform. Known-answer vectors for real providers are further down.
final class EncryptedSecretEnvelopeTests: XCTestCase {
    func testPassphrasesAreTrimmedAndLengthCheckedLikeEnablingSync() throws {
        let typed = "  correct horse battery\n"
        XCTAssertEqual(try EncryptedSecretEnvelope.normalizedPassphrase(typed), "correct horse battery")
        XCTAssertThrowsError(try EncryptedSecretEnvelope.normalizedPassphrase(" \n ")) {
            XCTAssertEqual($0 as? CloudKitKeySyncError, .missingPassphrase)
        }
        XCTAssertThrowsError(try EncryptedSecretEnvelope.normalizedPassphrase("short")) {
            XCTAssertEqual($0 as? CloudKitKeySyncError, .passphraseTooShort(minimumLength: 12))
        }
    }

    func testKeysAreDerivedOverTheSaltAndTheVersionedInfo() throws {
        let provider = FakeEnvelopeCryptography()
        let envelope = EncryptedSecretEnvelope(cryptography: provider)

        _ = try envelope.deriveKey(passphrase: "passphrase-1234", salt: Data([9, 9]))

        let request = try XCTUnwrap(provider.derivations.first)
        XCTAssertEqual(request.password, Data("passphrase-1234".utf8))
        XCTAssertEqual(request.salt, Data([9, 9]) + Data("justspeaktoit.api-key-sync.v1".utf8))
        XCTAssertEqual(request.iterations, 210_000)
    }

    func testWrongPassphraseIsRejectedBeforeAnySecretIsOpened() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: FakeEnvelopeCryptography())
        let created = try envelope.makeMetadata(passphrase: "passphrase-one")

        XCTAssertEqual(created.metadata.salt.count, 32)
        XCTAssertEqual(try envelope.unlock(created.metadata, passphrase: "passphrase-one"), created.key)
        XCTAssertThrowsError(try envelope.unlock(created.metadata, passphrase: "passphrase-two")) {
            XCTAssertEqual($0 as? CloudKitKeySyncError, .incorrectPassphrase)
        }
    }

    func testProvidersThatBreakTheStoredFormatAreRefused() throws {
        let key = Data(repeating: 1, count: 32)
        let appendsTag = EncryptedSecretEnvelope(cryptography: FakeEnvelopeCryptography(quirk: .tagInCiphertext))
        XCTAssertThrowsError(try appendsTag.seal(identifier: "a", value: "v", updatedAt: Date(), key: key)) {
            XCTAssertEqual($0 as? CloudKitKeySyncError, .encryptionFailed)
        }
        let noRandomness = EncryptedSecretEnvelope(cryptography: FakeEnvelopeCryptography(quirk: .noRandomness))
        XCTAssertThrowsError(try noRandomness.makeMetadata(passphrase: "passphrase-one")) {
            XCTAssertEqual($0 as? CloudKitKeySyncError, .randomGenerationFailed)
        }
        let envelope = EncryptedSecretEnvelope(cryptography: FakeEnvelopeCryptography())
        XCTAssertThrowsError(try envelope.seal(identifier: "a", value: "v", updatedAt: Date(), key: Data([1]))) {
            XCTAssertEqual($0 as? CloudKitKeySyncError, .encryptionFailed)
        }
        let sealed = try envelope.seal(identifier: "a", value: "v", updatedAt: Date(), key: key)
        let truncated = EncryptedSecret(
            identifier: "a",
            ciphertext: sealed.ciphertext,
            nonce: sealed.nonce.dropLast(),
            tag: sealed.tag,
            updatedAt: Date()
        )
        XCTAssertThrowsError(try envelope.open(truncated, key: key))
        XCTAssertEqual(try envelope.open(sealed, key: key), "v")
    }
}

/// Records derivations and pairs sealed boxes with their key. Not encryption.
private final class FakeEnvelopeCryptography: SyncEnvelopeCryptography, @unchecked Sendable {
    enum Quirk {
        case none
        case tagInCiphertext
        case noRandomness
    }

    struct Derivation {
        let password: Data
        let salt: Data
        let iterations: Int
    }

    private let lock = NSLock()
    private let quirk: Quirk
    private var storedDerivations: [Derivation] = []
    private var boxes: [Data: (key: Data, plaintext: Data)] = [:]
    private var counter: UInt8 = 0

    init(quirk: Quirk = .none) {
        self.quirk = quirk
    }

    var derivations: [Derivation] { lock.withLock { storedDerivations } }

    func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data {
        lock.withLock { storedDerivations.append(Derivation(password: password, salt: salt, iterations: iterations)) }
        var key = Data(repeating: 0, count: keyByteCount)
        for (index, byte) in (password + salt).enumerated() {
            key[index % keyByteCount] ^= byte
        }
        return key
    }

    func sealAESGCM(_ plaintext: Data, key: Data) throws -> SealedEnvelopePayload {
        let nonce: Data = lock.withLock {
            counter &+= 1
            return Data(repeating: counter, count: 12)
        }
        lock.withLock { boxes[nonce] = (key, plaintext) }
        let tag = Data(repeating: 0xAB, count: 16)
        let ciphertext = Data(plaintext.reversed())
        let stored = quirk == .tagInCiphertext ? ciphertext + tag : ciphertext
        return SealedEnvelopePayload(nonce: nonce, ciphertext: stored, tag: tag)
    }

    func openAESGCM(_ sealed: SealedEnvelopePayload, key: Data) throws -> Data {
        guard let box = lock.withLock({ boxes[sealed.nonce] }), box.key == key else {
            throw CloudKitWebTestError.injected
        }
        return box.plaintext
    }

    func randomBytes(count: Int) throws -> Data {
        guard quirk != .noRandomness else { throw CloudKitWebTestError.injected }
        return Data(repeating: 0x5A, count: count)
    }
}

#if canImport(CryptoKit) && canImport(CommonCrypto)
/// Vectors computed independently of CryptoKit: PBKDF2 with Python's hashlib and
/// AES-256-GCM with OpenSSL (Python `cryptography`). A Windows CNG provider must
/// pass the same vectors before it is used.
final class EncryptedSecretEnvelopeVectorTests: XCTestCase {
    private let derivedKeyHex = "896bd7f68f1b80b27ed4895a83436bc12858064354495643ed4afc497ee6b775"
    private let nonceHex = "000102030405060708090a0b"
    private let verifierCiphertextHex = "4bcfe0c96a63654c8eb20450804119f724b56951edb26b9a6125136a26d3da4430281d0dfb21"

    func testPBKDF2MatchesTheStandardVector() throws {
        let derived = try AppleTestEnvelopeCryptography().pbkdf2SHA256(
            password: Data("password".utf8),
            salt: Data("salt".utf8),
            iterations: 4_096,
            keyByteCount: 32
        )
        XCTAssertEqual(derived.hex, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testEnvelopeKeyMatchesTheIndependentDerivation() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: AppleTestEnvelopeCryptography())
        let salt = Data("stable-test-salt".utf8)
        let key = try envelope.deriveKey(passphrase: "correct horse battery staple", salt: salt)
        XCTAssertEqual(key.hex, derivedKeyHex)
    }

    func testEnvelopeOpensSecretsAndVerifiersSealedByAnotherImplementation() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: AppleTestEnvelopeCryptography())
        let key = try XCTUnwrap(Data(hex: derivedKeyHex))
        let nonce = try XCTUnwrap(Data(hex: nonceHex))
        let secret = EncryptedSecret(
            identifier: "openai.apiKey",
            ciphertext: try XCTUnwrap(Data(hex: "52c3fdc97176744486eb0a499d4213e234b57455f8ea7d")),
            nonce: nonce,
            tag: try XCTUnwrap(Data(hex: "06a7994a9c79afb5bba6b8b6162449dc")),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
        XCTAssertEqual(try envelope.open(secret, key: key), "synthetic-api-key-value")

        let metadata = KeySyncMetadata(
            salt: Data("stable-test-salt".utf8),
            verifierNonce: nonce,
            verifierCiphertext: try XCTUnwrap(Data(hex: verifierCiphertextHex)),
            verifierTag: try XCTUnwrap(Data(hex: "c0e2d7a8447a27a984ab86407946380e"))
        )
        XCTAssertEqual(try envelope.unlock(metadata, passphrase: "correct horse battery staple"), key)
        XCTAssertThrowsError(try envelope.unlock(metadata, passphrase: "incorrect horse battery staple"))
    }

    func testSealedSecretsRoundTripWithFreshNonces() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: AppleTestEnvelopeCryptography())
        let key = try XCTUnwrap(Data(hex: derivedKeyHex))
        let first = try envelope.seal(identifier: "openai.apiKey", value: "synthetic", updatedAt: Date(), key: key)
        let second = try envelope.seal(identifier: "openai.apiKey", value: "synthetic", updatedAt: Date(), key: key)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertEqual(try envelope.open(first, key: key), "synthetic")
        XCTAssertThrowsError(try envelope.open(first, key: Data(repeating: 0, count: 32)))
    }
}

/// CommonCrypto PBKDF2 and CryptoKit AES-GCM, for the vectors above only.
private struct AppleTestEnvelopeCryptography: SyncEnvelopeCryptography {
    func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data {
        var derived = Data(count: keyByteCount)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyByteCount
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw CloudKitWebTestError.injected }
        return derived
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
            throw CloudKitWebTestError.injected
        }
        return Data(bytes)
    }
}

private extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
#endif
