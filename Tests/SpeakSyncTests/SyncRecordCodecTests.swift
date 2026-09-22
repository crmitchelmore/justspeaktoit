import Foundation
import SpeakCore
import XCTest

@testable import SpeakSync

/// The one record schema shared by the native adapters and the web transport.
final class SyncRecordCodecTests: XCTestCase {
    func testHistoryWritesTheNineProjectedFieldsInTheNativeOrderAndTypes() {
        let entry = SyncWireFixture.entry(raw: "raw text", processed: nil)
        let assignments = HistoryRecordCodec.assignments(for: entry)

        XCTAssertEqual(assignments.map { $0.key }, [
            "entryID", "createdAt", "rawTranscription", "postProcessedText", "model",
            "duration", "wordCount", "originPlatform", "updatedAt"
        ])
        XCTAssertEqual(assignments.map { $0.value }, [
            .string(entry.id.uuidString), .timestamp(entry.createdAt), .string("raw text"), nil,
            .string("openai/gpt-4o-transcribe"), .double(2.5), .int64(2), .string("windows"),
            .timestamp(entry.updatedAt)
        ])
    }

    func testHistoryRoundTripsThroughTheWireFormat() throws {
        let entry = SyncWireFixture.entry(raw: "raw", processed: "processed")
        let record = try SyncWireFixture.record(
            name: entry.id.uuidString,
            type: SyncSchema.History.recordType,
            assignments: HistoryRecordCodec.assignments(for: entry)
        )
        assertSameEntry(HistoryRecordCodec.entry(from: record), entry)
    }

    func testHistoryReadsASparseRecordWithTheNativeDefaults() throws {
        let entryID = UUID()
        let created = Date(timeIntervalSince1970: 1_800_000_000.25)
        let record = try SyncWireFixture.record(
            name: entryID.uuidString,
            type: SyncSchema.History.recordType,
            assignments: [
                (HistoryRecordField.entryID, .string(entryID.uuidString)),
                (HistoryRecordField.createdAt, .timestamp(created))
            ]
        )

        let entry = try XCTUnwrap(HistoryRecordCodec.entry(from: record))
        XCTAssertEqual(entry.model, "unknown")
        XCTAssertEqual(entry.originPlatform, "unknown")
        XCTAssertEqual(entry.duration, 0)
        XCTAssertEqual(entry.wordCount, 0)
        XCTAssertEqual(entry.updatedAt, created)
        XCTAssertNil(entry.rawTranscription)
    }

    func testHistoryFeedClassificationMatchesTheNativeTransport() throws {
        let entryID = UUID()
        let name = entryID.uuidString
        let secret = try SyncWireFixture.record(name: "secret-b3BlbmFp", type: "EncryptedSecret", assignments: [])
        let partial = try SyncWireFixture.record(
            name: name,
            type: SyncSchema.History.recordType,
            assignments: [(HistoryRecordField.entryID, .string(name))]
        )
        XCTAssertNil(HistoryRecordCodec.change(from: secret), "other record types share the zone")
        XCTAssertNil(HistoryRecordCodec.change(from: partial), "a History record without createdAt is skipped")

        XCTAssertEqual(HistoryRecordCodec.deletion(recordName: name, recordType: "TranscriptionHistory")?.id, entryID)
        XCTAssertNil(HistoryRecordCodec.deletion(recordName: name, recordType: "ModelComparisonRound"))
        XCTAssertEqual(HistoryRecordCodec.deletion(recordName: name, recordType: nil)?.id, entryID)
        XCTAssertNil(HistoryRecordCodec.deletion(recordName: "comparison-\(name)", recordType: nil))
        XCTAssertNil(HistoryRecordCodec.deletion(recordName: SyncSchema.KeySyncMetadata.recordName, recordType: nil))
    }

    func testRecordNamesOfEveryTypeAreDisjoint() {
        let sharedID = UUID()
        let names = [
            SyncSchema.History.recordName(for: sharedID),
            SyncSchema.ComparisonRound.recordName(for: sharedID),
            SyncSchema.EncryptedSecret.recordName(for: sharedID.uuidString),
            SyncSchema.KeySyncMetadata.recordName
        ]
        XCTAssertEqual(names.filter { SyncSchema.History.entryID(fromRecordName: $0) != nil }, [names[0]])
        XCTAssertEqual(names.filter { SyncSchema.ComparisonRound.roundID(fromRecordName: $0) != nil }, [names[1]])
        XCTAssertEqual(names.filter { SyncSchema.EncryptedSecret.identifier(fromRecordName: $0) != nil }, [names[2]])
    }

    func testSecretRecordNamesRoundTripEveryBase64Shape() {
        for identifier in ["openai.apiKey", "a", "ab", "abc", "?>?>", "~~~", "日本語.apiKey"] {
            let name = SyncSchema.EncryptedSecret.recordName(for: identifier)
            XCTAssertTrue(name.hasPrefix("secret-"))
            XCTAssertFalse(name.contains("+") || name.contains("/") || name.contains("="), name)
            XCTAssertEqual(SyncSchema.EncryptedSecret.identifier(fromRecordName: name), identifier)
        }
        XCTAssertEqual(SyncSchema.EncryptedSecret.recordName(for: "openai.apiKey"), "secret-b3BlbmFpLmFwaUtleQ")
    }

    func testComparisonRoundsAndTombstonesRoundTripThroughTheWireFormat() throws {
        let round = SyncWireFixture.round()
        let roundRecord = try SyncWireFixture.comparisonJSON(ModelComparisonRevision(round: round))
        let decodedRound = try JSONDecoder().decode(CloudKitWebRecord.self, from: CloudKitWebFixture.data(roundRecord))
        XCTAssertEqual(ComparisonRecordCodec.round(from: decodedRound), round)
        XCTAssertEqual(try ComparisonRecordCodec.revision(from: decodedRound), ModelComparisonRevision(round: round))

        let tombstone = ModelComparisonRevision(deleting: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000.125))
        let assignments = try ComparisonRecordCodec.assignments(for: tombstone)
        XCTAssertEqual(assignments.first { $0.key == "originPlatform" }?.value, .string("macos"))
        let tombstoneRecord = try SyncWireFixture.record(
            name: SyncSchema.ComparisonRound.recordName(for: tombstone.id),
            type: SyncSchema.ComparisonRound.recordType,
            assignments: assignments
        )
        XCTAssertEqual(try ComparisonRecordCodec.revision(from: tombstoneRecord), tombstone)
    }

    func testComparisonRecordsFromANewerSchemaAreNeverConsumed() throws {
        let revision = ModelComparisonRevision(round: SyncWireFixture.round())
        var newer = try ComparisonRecordCodec.assignments(for: revision)
        let versionIndex = try XCTUnwrap(newer.firstIndex { $0.key == "schemaVersion" })
        newer[versionIndex].value = .int64(Int64(ModelComparisonRound.schemaVersion + 1))
        let record = try SyncWireFixture.record(
            name: SyncSchema.ComparisonRound.recordName(for: revision.id),
            type: SyncSchema.ComparisonRound.recordType,
            assignments: newer
        )
        XCTAssertNil(ComparisonRecordCodec.round(from: record))
        XCTAssertThrowsError(try ComparisonRecordCodec.change(from: record))
        let history = try SyncWireFixture.record(name: "other", type: "TranscriptionHistory", assignments: newer)
        XCTAssertNil(try ComparisonRecordCodec.change(from: history), "other record types are skipped, not rejected")
    }

    func testSecretsAndKeySyncMetadataRoundTripOnlyUnderTheirOwnTypes() throws {
        let secret = EncryptedSecret(
            identifier: "assemblyai.apiKey",
            ciphertext: Data([1, 2, 3]),
            nonce: Data([4, 5, 6]),
            tag: Data([7, 8, 9]),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_001),
            isDeleted: true
        )
        let assignments = EncryptedSecretRecordCodec.assignments(for: secret)
        XCTAssertEqual(assignments.first { $0.key == "isDeleted" }?.value, .int64(1))
        let name = SyncSchema.EncryptedSecret.recordName(for: secret.identifier)
        let record = try SyncWireFixture.record(name: name, type: "EncryptedSecret", assignments: assignments)
        XCTAssertEqual(EncryptedSecretRecordCodec.secret(from: record), secret)
        let mistyped = try SyncWireFixture.record(name: name, type: "TranscriptionHistory", assignments: assignments)
        XCTAssertNil(EncryptedSecretRecordCodec.secret(from: mistyped))

        let metadata = KeySyncMetadata(
            salt: Data(repeating: 1, count: 32),
            verifierNonce: Data(repeating: 2, count: 12),
            verifierCiphertext: Data([3, 4]),
            verifierTag: Data(repeating: 5, count: 16)
        )
        let metadataAssignments = KeySyncMetadataRecordCodec.assignments(for: metadata, updatedAt: Date())
        let metadataRecord = try SyncWireFixture.record(
            name: SyncSchema.KeySyncMetadata.recordName,
            type: SyncSchema.KeySyncMetadata.recordType,
            assignments: metadataAssignments
        )
        XCTAssertEqual(KeySyncMetadataRecordCodec.metadata(from: metadataRecord), metadata)
    }

    func testContainerFamiliesReadTheReleaseTrainCatalogue() throws {
        for train in ReleaseTrain.allCases {
            XCTAssertEqual(SyncContainerFamily.macOS.containerIdentifier(in: train), train.macCloudContainer)
            XCTAssertEqual(SyncContainerFamily.iOS.containerIdentifier(in: train), train.iosCloudContainer)
            for family in SyncContainerFamily.allCases {
                XCTAssertNoThrow(try CloudKitWebServicesConfiguration(
                    family: family,
                    train: train,
                    environment: .production,
                    apiToken: CloudKitWebFixture.apiToken
                ))
            }
        }
        XCTAssertEqual(SyncContainerFamily.macOS.containerIdentifier(in: .stable), "iCloud.com.justspeaktoit")
        XCTAssertEqual(SyncContainerFamily.iOS.containerIdentifier(in: .stable), "iCloud.com.justspeaktoit.ios")
        XCTAssertTrue(SyncContainerFamily.macOS.carriesComparisonRounds)
        XCTAssertFalse(SyncContainerFamily.iOS.carriesComparisonRounds)
    }

    func testEveryCapabilityHasAnExplicitAssessmentAndUnsupportedOnesThrow() throws {
        for capability in CloudKitWebServicesCapability.allCases {
            XCTAssertNotEqual(capability.support, .unsupported(blocker: "Not assessed."), capability.rawValue)
        }
        let unsupported = CloudKitWebServicesCapability.allCases.filter {
            if case .unsupported = $0.support { return true }
            return false
        }
        XCTAssertEqual(
            Set(unsupported),
            [.changeNotifications, .nativeChangeTokenInterchange, .changeTokenExpiryRecovery, .assetTransfer]
        )
        for capability in unsupported {
            XCTAssertThrowsError(try capability.requireSupported()) {
                XCTAssertEqual($0 as? CloudKitWebServicesError, .unsupported(capability))
            }
        }
        XCTAssertNoThrow(try CloudKitWebServicesCapability.customZoneChangeFeed.requireSupported())
    }
}
