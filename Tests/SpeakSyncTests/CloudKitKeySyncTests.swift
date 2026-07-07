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
}
