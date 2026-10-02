import Foundation
import SpeakSync
import XCTest
import SpeakLinuxPlatform

/// OpenSSL must reproduce the API-key envelope exactly: these vectors were
/// computed independently (Python hashlib and OpenSSL) and are the same ones
/// the Apple CryptoKit and Windows CNG implementations are held to, so a key
/// the Mac sealed opens here.
final class LinuxEnvelopeCryptographyTests: XCTestCase {
    private let crypto = LinuxEnvelopeCryptography()
    private let derivedKeyHex = "896bd7f68f1b80b27ed4895a83436bc12858064354495643ed4afc497ee6b775"

    func testPBKDF2MatchesTheStandardVector() throws {
        let derived = try crypto.pbkdf2SHA256(
            password: Data("password".utf8), salt: Data("salt".utf8), iterations: 4_096, keyByteCount: 32
        )
        XCTAssertEqual(derived.hex, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testTheEnvelopeDerivesTheSameKeyAsAMac() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: crypto)
        let key = try envelope.deriveKey(
            passphrase: "correct horse battery staple", salt: Data("stable-test-salt".utf8)
        )
        XCTAssertEqual(key.hex, derivedKeyHex)
    }

    func testOpenSSLOpensWhatAnotherImplementationSealed() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: crypto)
        let key = try XCTUnwrap(Data(hex: derivedKeyHex))
        let nonce = try XCTUnwrap(Data(hex: "000102030405060708090a0b"))
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
            verifierCiphertext: try XCTUnwrap(Data(
                hex: "4bcfe0c96a63654c8eb20450804119f724b56951edb26b9a6125136a26d3da4430281d0dfb21"
            )),
            verifierTag: try XCTUnwrap(Data(hex: "c0e2d7a8447a27a984ab86407946380e"))
        )
        XCTAssertEqual(try envelope.unlock(metadata, passphrase: "correct horse battery staple"), key)
        XCTAssertThrowsError(try envelope.unlock(metadata, passphrase: "incorrect horse battery staple")) {
            XCTAssertEqual($0 as? CloudKitKeySyncError, .incorrectPassphrase)
        }
    }

    func testSealingUsesFreshNoncesAndNothingTamperedOpens() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: crypto)
        let key = try XCTUnwrap(Data(hex: derivedKeyHex))
        let first = try envelope.seal(identifier: "openai.apiKey", value: "synthetic", updatedAt: Date(), key: key)
        let second = try envelope.seal(identifier: "openai.apiKey", value: "synthetic", updatedAt: Date(), key: key)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertEqual(first.ciphertext.count, "synthetic".utf8.count, "the tag is kept apart from the ciphertext")
        XCTAssertEqual(try envelope.open(first, key: key), "synthetic")

        var tag = first.tag
        tag[tag.startIndex] ^= 1
        var ciphertext = first.ciphertext
        ciphertext[ciphertext.startIndex] ^= 1
        for (tamperedTag, tamperedCiphertext) in [(tag, first.ciphertext), (first.tag, ciphertext)] {
            let tampered = EncryptedSecret(
                identifier: first.identifier, ciphertext: tamperedCiphertext, nonce: first.nonce, tag: tamperedTag,
                updatedAt: first.updatedAt
            )
            XCTAssertThrowsError(try envelope.open(tampered, key: key))
        }
        XCTAssertThrowsError(try envelope.open(first, key: Data(repeating: 0, count: 32)))
    }

    func testAnEmptyValueRoundTripsAndOnly256BitKeysAreAccepted() throws {
        let key = try XCTUnwrap(Data(hex: derivedKeyHex))
        let sealed = try crypto.sealAESGCM(Data(), key: key)
        XCTAssertEqual(sealed.ciphertext, Data())
        XCTAssertEqual(sealed.tag.count, 16)
        XCTAssertEqual(try crypto.openAESGCM(sealed, key: key), Data())
        XCTAssertThrowsError(try crypto.sealAESGCM(Data("value".utf8), key: Data(repeating: 1, count: 16)))
        XCTAssertThrowsError(try crypto.openAESGCM(sealed, key: key.prefix(31)))
    }

    func testRandomBytesComeFromTheSystemGenerator() throws {
        let first = try crypto.randomBytes(count: 32)
        let second = try crypto.randomBytes(count: 32)
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try crypto.randomBytes(count: 0), Data())
    }
}

extension Data {
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
