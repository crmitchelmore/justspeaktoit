#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
@testable import SpeakCore
import XCTest

/// Known-answer and interoperability checks for the portable Send to Mac
/// crypto that Windows and Linux receivers use in place of CryptoKit.
final class TransportPortableCryptoTests: XCTestCase {
    func testSHA256_matchesFIPSVectors() {
        XCTAssertEqual(hex(PortableSHA256.hash(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(PortableSHA256.hash([])),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            hex(PortableSHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        let message = (0..<300).map { UInt8(truncatingIfNeeded: $0) }
        var hasher = PortableSHA256()
        for split in stride(from: 0, to: message.count, by: 37) {
            hasher.update(Array(message[split..<min(split + 37, message.count)]))
        }
        XCTAssertEqual(hasher.finalize(), PortableSHA256.hash(message))
    }

    func testHMACSHA256_matchesRFC4231Vectors() {
        XCTAssertEqual(
            hex(PortableHMACSHA256.authenticationCode(
                key: [UInt8](repeating: 0x0B, count: 20), message: Array("Hi There".utf8)
            )),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        )
        XCTAssertEqual(
            hex(PortableHMACSHA256.authenticationCode(
                key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8)
            )),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        )
        XCTAssertEqual(
            hex(PortableHMACSHA256.authenticationCode(
                key: [UInt8](repeating: 0xAA, count: 131),
                message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8)
            )),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        )
    }

    func testHKDF_matchesRFC5869Vector() {
        let okm = PortableHKDF.deriveKey(
            inputKeyMaterial: [UInt8](repeating: 0x0B, count: 22), salt: Array(0x00...0x0C),
            info: Array(0xF0...0xF9), outputByteCount: 42
        )
        XCTAssertEqual(
            hex(okm),
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        )
    }

    func testChaChaPoly_matchesRFC8439AEADVector() throws {
        let plaintext = Array(("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for "
            + "the future, sunscreen would be it.").utf8)
        let key = Array(UInt8(0x80)...UInt8(0x9F))
        let nonce: [UInt8] = [0x07, 0x00, 0x00, 0x00, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47]
        let aad: [UInt8] = [0x50, 0x51, 0x52, 0x53, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7]
        let sealed = PortableChaChaPoly.seal(plaintext, key: key, nonce: nonce, authenticating: aad)
        XCTAssertEqual(
            hex(sealed),
            "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b"
                + "1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
                + "3ff4def08e4b7a9de576d26586cec64b6116" + "1ae10b594f09e26a7e902ecbd0600691"
        )
        XCTAssertEqual(PortableChaChaPoly.open(sealed, key: key, nonce: nonce, authenticating: aad), plaintext)
        var tampered = sealed
        tampered[0] ^= 1
        XCTAssertNil(PortableChaChaPoly.open(tampered, key: key, nonce: nonce, authenticating: aad))
        XCTAssertNil(PortableChaChaPoly.open(sealed, key: key, nonce: nonce, authenticating: aad + [0]))
        XCTAssertNil(PortableChaChaPoly.open(Array(sealed.prefix(15)), key: key, nonce: nonce, authenticating: aad))
    }

    func testX25519_matchesRFC7748Vectors() throws {
        let alice = bytes("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let bob = bytes("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        XCTAssertEqual(hex(PortableX25519.publicKey(privateKey: alice)),
                       "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        let bobPublic = PortableX25519.publicKey(privateKey: bob)
        XCTAssertEqual(hex(bobPublic), "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = try XCTUnwrap(PortableX25519.sharedSecret(privateKey: alice, peerPublicKey: bobPublic))
        XCTAssertEqual(hex(shared), "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

        let scalar = bytes("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        let point = bytes("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        XCTAssertEqual(hex(try XCTUnwrap(PortableX25519.sharedSecret(privateKey: scalar, peerPublicKey: point))),
                       "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
        XCTAssertNil(PortableX25519.sharedSecret(privateKey: alice, peerPublicKey: [UInt8](repeating: 0, count: 31)))
    }

    func testChaChaPoly_roundTripsEveryLengthAroundBlockBoundaries() {
        let key = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        let nonce = (0..<12).map { _ in UInt8.random(in: .min ... .max) }
        for length in [0, 1, 15, 16, 17, 63, 64, 65, 127, 128, 129, 1000] {
            let plaintext = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31) }
            let sealed = PortableChaChaPoly.seal(plaintext, key: key, nonce: nonce, authenticating: [1, 2, 3])
            XCTAssertEqual(sealed.count, length + 16)
            XCTAssertEqual(PortableChaChaPoly.open(sealed, key: key, nonce: nonce, authenticating: [1, 2, 3]), plaintext)
        }
    }

    #if canImport(CryptoKit)
    func testPrimitives_agreeWithCryptoKitOnRandomInputs() throws {
        for length in [0, 1, 31, 55, 56, 63, 64, 65, 200, 4097] {
            let message = (0..<length).map { _ in UInt8.random(in: .min ... .max) }
            let key = (0..<(length % 80 + 1)).map { _ in UInt8.random(in: .min ... .max) }
            XCTAssertEqual(PortableSHA256.hash(message), Array(SHA256.hash(data: message)))
            XCTAssertEqual(
                PortableHMACSHA256.authenticationCode(key: key, message: message),
                Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
            )
            let okm = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: message), salt: key, info: Data("info".utf8), outputByteCount: 32
            )
            XCTAssertEqual(
                PortableHKDF.deriveKey(inputKeyMaterial: message, salt: key, info: Array("info".utf8), outputByteCount: 32),
                okm.withUnsafeBytes { Array($0) }
            )

            let aeadKey = SymmetricKey(size: .bits256)
            let keyBytes = aeadKey.withUnsafeBytes { Array($0) }
            let nonce = ChaChaPoly.Nonce()
            let nonceBytes = Array(nonce)
            let box = try ChaChaPoly.seal(message, using: aeadKey, nonce: nonce, authenticating: key)
            XCTAssertEqual(
                PortableChaChaPoly.seal(message, key: keyBytes, nonce: nonceBytes, authenticating: key),
                Array(box.ciphertext) + Array(box.tag)
            )
        }
        for _ in 0..<8 {
            let ours = PortableX25519.generatePrivateKey()
            let theirs = Curve25519.KeyAgreement.PrivateKey()
            let ourPublic = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: PortableX25519.publicKey(privateKey: ours)
            )
            let expected = try theirs.sharedSecretFromKeyAgreement(with: ourPublic).withUnsafeBytes { Array($0) }
            XCTAssertEqual(
                PortableX25519.sharedSecret(privateKey: ours, peerPublicKey: Array(theirs.publicKey.rawRepresentation)),
                expected
            )
        }
    }
    #endif

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return result
    }
}
