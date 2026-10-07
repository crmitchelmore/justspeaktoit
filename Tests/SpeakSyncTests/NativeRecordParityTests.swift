import CloudKit
import CryptoKit
import SpeakCore
import XCTest

@testable import SpeakSync

/// The native CKRecord mappers and the CloudKit Web Services codec write the
/// same fields with the same value types, and the portable envelope opens what
/// the production CryptoKit implementation seals (and the reverse).
final class NativeRecordParityTests: XCTestCase {
    func testHistoryRecordsCarryTheSharedFieldsAndTypes() {
        let entry = SyncableHistoryEntry(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            rawTranscription: "raw",
            postProcessedText: nil,
            model: "openai/gpt-4o-transcribe",
            duration: 2.5,
            wordCount: 3,
            originPlatform: "macos",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001.5)
        )
        let record = SyncRecord.record(from: entry)

        assertRecord(record, holds: HistoryRecordCodec.assignments(for: entry))
        XCTAssertEqual(record.recordType, SyncSchema.History.recordType)
        XCTAssertEqual(record.recordID.recordName, SyncSchema.History.recordName(for: entry.id))
        XCTAssertEqual(record.recordID.zoneID.zoneName, SyncSchema.zoneName)
        XCTAssertEqual(record.recordID.zoneID.ownerName, CKCurrentUserDefaultName)
    }

    func testComparisonAndSecretRecordsCarryTheSharedFieldsAndTypes() throws {
        let revision = ModelComparisonRevision(deleting: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000.125))
        let tombstone = try ComparisonSyncRecord.record(from: revision)
        assertRecord(tombstone, holds: try ComparisonRecordCodec.assignments(for: revision))
        XCTAssertEqual(tombstone.recordID.recordName, SyncSchema.ComparisonRound.recordName(for: revision.id))

        let secret = EncryptedSecret(
            identifier: "openai.apiKey",
            ciphertext: Data([1, 2, 3]),
            nonce: Data(repeating: 4, count: 12),
            tag: Data(repeating: 5, count: 16),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000),
            isDeleted: false
        )
        let secretRecord = EncryptedSecretRecordMapper.record(from: secret)
        assertRecord(secretRecord, holds: EncryptedSecretRecordCodec.assignments(for: secret))
        XCTAssertEqual(secretRecord.recordID.recordName, "secret-b3BlbmFpLmFwaUtleQ")
    }

    func testEnvelopeSeamInteroperatesWithTheProductionCryptoKitImplementation() throws {
        let salt = Data("stable-test-salt".utf8)
        let passphrase = "correct horse battery staple"
        let envelope = EncryptedSecretEnvelope(cryptography: CryptoKitSyncEnvelopeCryptography())
        let portableKey = try envelope.deriveKey(passphrase: passphrase, salt: salt)
        let nativeKey = EncryptedSecretCrypto.deriveKey(passphrase: passphrase, salt: salt)
        XCTAssertEqual(portableKey, nativeKey.withUnsafeBytes { Data($0) })

        let updatedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let sealed = try envelope.seal(
            identifier: "openai.apiKey",
            value: "synthetic-1",
            updatedAt: updatedAt,
            key: portableKey
        )
        XCTAssertEqual(try EncryptedSecretCrypto.decryptSecret(sealed, key: nativeKey), "synthetic-1")
        let native = try EncryptedSecretCrypto.encryptSecret(
            identifier: "openai.apiKey",
            value: "synthetic-2",
            updatedAt: updatedAt,
            key: nativeKey
        )
        XCTAssertEqual(try envelope.open(native, key: portableKey), "synthetic-2")

        let token = try EncryptedSecretCrypto.makeVerificationToken(key: nativeKey)
        let metadata = KeySyncMetadata(
            salt: salt,
            verifierNonce: token.nonce,
            verifierCiphertext: token.ciphertext,
            verifierTag: token.tag
        )
        XCTAssertEqual(try envelope.unlock(metadata, passphrase: passphrase), portableKey)
    }

    private func assertRecord(
        _ record: CKRecord,
        holds assignments: SyncRecordFieldAssignments,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for assignment in assignments {
            let stored = record[assignment.key]
            switch assignment.value {
            case nil:
                XCTAssertNil(stored, assignment.key, file: file, line: line)
            case .string(let text)?:
                XCTAssertEqual(stored as? String, text, assignment.key, file: file, line: line)
            case .int64(let integer)?:
                XCTAssertEqual(stored as? Int, Int(integer), assignment.key, file: file, line: line)
            case .double(let number)?:
                XCTAssertEqual(stored as? Double, number, assignment.key, file: file, line: line)
            case .timestamp(let date)?:
                XCTAssertEqual(stored as? Date, date, assignment.key, file: file, line: line)
            case .bytes(let bytes)?:
                XCTAssertEqual(stored as? Data, bytes, assignment.key, file: file, line: line)
            }
        }
        let written = Set(assignments.compactMap { $0.value == nil ? nil : $0.key })
        XCTAssertEqual(Set(record.allKeys()), written, file: file, line: line)
    }
}
