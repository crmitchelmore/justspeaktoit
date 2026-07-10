import CloudKit
import CryptoKit
import XCTest
@testable import SpeakSync

final class CloudKitKeySyncTests: XCTestCase {
    func testEncryptDecryptRoundTripWithCorrectPassphrase() throws {
        let salt = Data("stable-test-salt".utf8)
        let key = EncryptedSecretCrypto.deriveKey(passphrase: "correct horse battery staple", salt: salt)
        let updatedAt = Date(timeIntervalSince1970: 1_720_000_000)

        let encrypted = try EncryptedSecretCrypto.encryptSecret(
            identifier: "openai.apiKey",
            value: "secret-value",
            updatedAt: updatedAt,
            key: key
        )

        let decrypted = try EncryptedSecretCrypto.decryptSecret(encrypted, key: key)
        XCTAssertEqual(decrypted, "secret-value")
        XCTAssertEqual(encrypted.identifier, "openai.apiKey")
        XCTAssertEqual(encrypted.updatedAt, updatedAt)
    }

    func testDecryptFailsWithIncorrectPassphrase() throws {
        let salt = Data("stable-test-salt".utf8)
        let correctKey = EncryptedSecretCrypto.deriveKey(passphrase: "correct", salt: salt)
        let wrongKey = EncryptedSecretCrypto.deriveKey(passphrase: "incorrect", salt: salt)
        let encrypted = try EncryptedSecretCrypto.encryptSecret(
            identifier: "deepgram.apiKey",
            value: "secret-value",
            updatedAt: Date(),
            key: correctKey
        )

        XCTAssertThrowsError(try EncryptedSecretCrypto.decryptSecret(encrypted, key: wrongKey))
    }

    func testEncryptedSecretRecordRoundTrip() {
        let updatedAt = Date(timeIntervalSince1970: 1_720_000_001)
        let secret = EncryptedSecret(
            identifier: "assemblyai.apiKey",
            ciphertext: Data([1, 2, 3]),
            nonce: Data([4, 5, 6]),
            tag: Data([7, 8, 9]),
            updatedAt: updatedAt,
            isDeleted: true
        )

        let record = EncryptedSecretRecordMapper.record(from: secret)
        let mapped = EncryptedSecretRecordMapper.secret(from: record)

        XCTAssertEqual(record.recordType, EncryptedSecretRecordMapper.recordType)
        XCTAssertEqual(record.recordID.recordName, EncryptedSecretRecordMapper.recordName(for: secret.identifier))
        XCTAssertEqual(mapped, secret)
    }

    func testDeriveKeyOffMainActor_MatchesSynchronousDerivation() async {
        let salt = Data("stable-test-salt".utf8)
        let expected = EncryptedSecretCrypto.deriveKey(
            passphrase: "correct horse battery staple",
            salt: salt
        )
        let actual = await EncryptedSecretCrypto.deriveKeyOffMainActor(
            passphrase: "correct horse battery staple",
            salt: salt
        )

        XCTAssertEqual(
            expected.withUnsafeBytes { Data($0) },
            actual.withUnsafeBytes { Data($0) }
        )
    }

    func testPendingMutation_CodableRoundTripsDeletion() throws {
        let mutation = PendingKeySyncMutation(
            operationID: UUID(uuidString: "E30F13E5-8DAB-4D46-8BD1-5566B3D72893")!,
            identifier: "openai.apiKey",
            updatedAt: Date(timeIntervalSince1970: 1_720_000_002),
            kind: .deletion
        )

        let encoded = try JSONEncoder().encode(mutation)
        let decoded = try JSONDecoder().decode(PendingKeySyncMutation.self, from: encoded)

        XCTAssertEqual(decoded, mutation)
    }

    func testPBKDF2SHA256_MatchesIndependentKnownAnswerVector() {
        let derived = EncryptedSecretCrypto.pbkdf2SHA256(
            password: Data("password".utf8),
            salt: Data("salt".utf8),
            iterations: 4_096,
            keyByteCount: 32
        )

        XCTAssertEqual(
            derived.map { String(format: "%02x", $0) }.joined(),
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"
        )
    }
}
