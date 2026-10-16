import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopRecordingMigrationSnapshotTests: XCTestCase {
    private let digests = LocalModelDigestProvider(name: "Constant fixture digest, not a hash implementation") {
        SnapshotFixtureHasher()
    }

    private func store() throws -> DesktopRecordingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try DesktopRecordingStore(directory: root)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return store
    }

    private func save(
        _ store: DesktopRecordingStore, filename: String? = nil, createdAt: Date = Date(timeIntervalSince1970: 100)
    ) async throws -> DesktopRecordingStore.Record {
        let id = UUID()
        let name = filename ?? id.uuidString + ".wav"
        let directory = await store.directory
        try Data("Synthetic audio".utf8).write(to: directory.appendingPathComponent(name))
        var record = DesktopRecordingStore.Record(id: id, audioFilename: name, modelIdentifier: "openai/whisper-1",
                                                  createdAt: createdAt)
        record.recordedDuration = 2
        record.processedText = "Retained text"
        try await store.save(record)
        return record
    }

    func testCollector_ProducesValidatedHistoryAndRedactedAudioWithMatchingRevisions() async throws {
        let store = try store()
        let directory = await store.directory
        let record = try await save(store)
        let result = try await store.migrationSnapshot(categories: [.history, .recordings], digests: digests)
        let history = try XCTUnwrap(result.records[.history]?.first)
        let audio = try XCTUnwrap(result.records[.recordings]?.first)
        XCTAssertEqual(history.id, record.id.uuidString)
        XCTAssertEqual(audio.id, history.id)
        XCTAssertEqual(audio.revision, history.revision)
        XCTAssertEqual(try DataMigrationHistorySchema.validate(history, category: .history).postProcessedTranscription,
                       record.processedText)
        XCTAssertNil(try DataMigrationHistorySchema.validate(audio, category: .recordings).postProcessedTranscription)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(audio.digest, String(repeating: "a", count: 64))
        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertEqual(result.manifest.version, 2)
        XCTAssertEqual(result.manifest.scopes["history"]?.selectedKinds, ["history"])
        XCTAssertFalse(result.manifest.scopes["history"]?.isComplete == true)
        let archive = try MigrationTestArchive.export(result, digests: digests, stagingRoot: directory)
        let read = try MigrationTestArchive.read(archive, digests: digests, stagingRoot: directory)
        XCTAssertEqual(read.records, result.records)
        XCTAssertEqual(read.manifest.scopes["history"]?.selectedKinds, ["history"])
    }

    func testScopesAndActiveAudioExclusion_DoNotExportUnfinishedOrUnselectedRecords() async throws {
        let store = try store()
        let first = try await save(store)
        let second = try await save(store)
        let excluded = try await store.migrationSnapshot(categories: [.history, .recordings],
                                                        excludingAudio: [first.audioFilename], digests: digests)
        XCTAssertEqual(excluded.records[.history]?.map(\.id), [second.id.uuidString])
        XCTAssertEqual(excluded.records[.recordings]?.map(\.id), [second.id.uuidString])
        let scopes = ["history": DataMigrationScope(selectedIDs: [first.id.uuidString]),
                      "recordings": DataMigrationScope(end: first.createdAt)]
        let selected = try await store.migrationSnapshot(categories: [.history, .recordings],
                                                        scopes: scopes, digests: digests)
        XCTAssertEqual(selected.records[.history]?.map(\.id), [first.id.uuidString])
        XCTAssertEqual(selected.records[.recordings], [])
        XCTAssertTrue(selected.files.isEmpty)
    }

    func testFractionalCreationDate_ProducesCanonicalArchiveRecordDatesWithoutLosingNativeTimestamp() async throws {
        let store = try store()
        let directory = await store.directory
        let createdAt = Date(timeIntervalSince1970: 100.625)
        let original = try await save(store, createdAt: createdAt)
        let source = try await store.migrationSnapshot(categories: [.history, .recordings], digests: digests)
        let archive = try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory)
        let result = try MigrationTestArchive.read(archive, digests: digests, stagingRoot: directory)
        XCTAssertEqual(result.records, source.records)
        let history = try XCTUnwrap(result.records[.history]?.first)
        XCTAssertEqual(history.date, Date(timeIntervalSince1970: 100))
        let restored = try DesktopMigrationHistory.record(history, category: .history)
        XCTAssertEqual(restored.createdAt, createdAt)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(try DesktopMigrationHistory.value(restored), history.value)
    }

    func testFractionalScopeBoundaries_AreRejectedInsteadOfSilentlyChangingExclusiveEnd() async throws {
        let store = try store()
        _ = try await save(store, createdAt: Date(timeIntervalSince1970: 100.625))
        for scope in [
            DataMigrationScope(start: Date(timeIntervalSince1970: 100.25)),
            DataMigrationScope(end: Date(timeIntervalSince1970: 100.75))
        ] {
            do {
                _ = try await store.migrationSnapshot(categories: [.history],
                                                      scopes: ["history": scope], digests: digests)
                XCTFail("A fractional scope changed silently through the version-1 date codec.")
            } catch { XCTAssertTrue(error.localizedDescription.contains("whole-second")) }
        }
    }

    func testSharedOwnedAudio_ExportsEachRetainedHistoryIdentity() async throws {
        let store = try store()
        _ = try await save(store, filename: "shared.wav")
        _ = try await save(store, filename: "shared.wav")
        let result = try await store.migrationSnapshot(categories: [.history, .recordings], digests: digests)
        XCTAssertEqual(result.records[.history]?.count, 2)
        XCTAssertEqual(result.records[.recordings]?.count, 2)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(Set(result.files.values).count, 1)
    }

    func testMissingReferencedAudio_ReportsPreservationAndCannotExportDestructiveEmptyCategory() async throws {
        let store = try store()
        let directory = await store.directory
        let record = try await save(store)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(record.audioFilename))
        let result = try await store.migrationSnapshot(categories: [.history, .recordings], digests: digests)
        XCTAssertEqual(result.records[.recordings], [])
        XCTAssertEqual(result.notices, ["Recordings, \(record.id.uuidString): file unavailable; skipped."])
        XCTAssertThrowsError(try MigrationTestArchive.export(result, digests: digests, stagingRoot: directory))
        let text = try await store.migrationSnapshot(categories: [.history], digests: digests)
        XCTAssertTrue(text.notices.isEmpty)
        XCTAssertEqual(text.records[.history]?.count, 1)
    }

    func testStandaloneOwnedAudio_UsesStableIdentityAndNeverCreatesHistoryText() async throws {
        let store = try store()
        let directory = await store.directory
        let filename = UUID().uuidString + ".wav"
        try Data("Synthetic orphan".utf8).write(to: directory.appendingPathComponent(filename))
        let first = try await store.migrationSnapshot(categories: [.history, .recordings], digests: digests)
        let second = try await store.migrationSnapshot(categories: [.history, .recordings], digests: digests)
        XCTAssertEqual(first.records[.history], [])
        XCTAssertEqual(first.records[.recordings], second.records[.recordings])
        let record = try XCTUnwrap(first.records[.recordings]?.first)
        XCTAssertNotNil(UUID(uuidString: record.id))
        XCTAssertEqual(try DataMigrationHistorySchema.validate(record, category: .recordings).modelsUsed, [])
    }

    func testCollector_RejectsForeignCategoryAndUnavailableDigestProvider() async throws {
        let store = try store()
        _ = try await save(store)
        do {
            _ = try await store.migrationSnapshot(categories: [.settings], digests: digests)
            XCTFail("A recording collector accepted foreign settings ownership.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("owns only")) }
        let unavailable = LocalModelDigestProvider(name: "Unavailable fixture") {
            throw LocalModelDigestError.unavailable("Synthetic failure")
        }
        do {
            _ = try await store.migrationSnapshot(categories: [.history], digests: unavailable)
            XCTFail("Unavailable hashing was hidden.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic failure")) }
    }

    func testStandaloneIdentifierCollision_IsRejectedRatherThanOverwritingArchiveAudio() async throws {
        let store = try store()
        let directory = await store.directory
        for _ in 0..<2 {
            try Data("Synthetic orphan".utf8)
                .write(to: directory.appendingPathComponent(UUID().uuidString + ".wav"))
        }
        do {
            _ = try await store.migrationSnapshot(categories: [.recordings], digests: digests)
            XCTFail("The deliberately colliding fixture digest silently replaced an audio entry.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Conflicting standalone")) }
    }

    func testDeletedHistoryWithKeptAudio_ExportsOnlySeparateStandaloneAudioIdentity() async throws {
        let store = try store()
        let record = try await save(store)
        try await store.delete(id: record.id, deleteAudio: false)
        let result = try await store.migrationSnapshot(categories: [.history, .recordings], digests: digests)
        XCTAssertEqual(result.records[.history], [])
        let audio = try XCTUnwrap(result.records[.recordings]?.first)
        XCTAssertNotEqual(audio.id, record.id.uuidString)
        XCTAssertNil(try DataMigrationHistorySchema.validate(audio, category: .recordings).postProcessedTranscription)
        let deleted = await store.isDeleted(id: record.id)
        XCTAssertTrue(deleted)
    }

    func testChangedAudioDuringHashing_FailsWithoutMutatingHistory() async throws {
        let store = try store()
        let record = try await save(store)
        let directory = await store.directory
        let url = directory.appendingPathComponent(record.audioFilename)
        let changing = LocalModelDigestProvider(name: "Mutating fixture, not a hash implementation") {
            MutatingSnapshotFixtureHasher {
                try Data("Changed synthetic audio of a different length".utf8).write(to: url)
            }
        }
        do {
            _ = try await store.migrationSnapshot(categories: [.recordings], digests: changing)
            XCTFail("A changed source file was admitted to the archive.")
        } catch { XCTAssertEqual(error as? DesktopRecordingAudioCleanupError, .changedFile) }
        let retained = try await store.record(id: record.id)
        XCTAssertEqual(retained.processedText, record.processedText)
    }

    func testCancelledCollection_FailsBeforeProducingSuccessShapedSnapshot() async throws {
        let store = try store()
        _ = try await save(store)
        let cancelling = LocalModelDigestProvider(name: "Cancelling fixture, not a hash implementation") {
            MutatingSnapshotFixtureHasher {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let task = Task { try await store.migrationSnapshot(categories: [.history], digests: cancelling) }
        do {
            _ = try await task.value
            XCTFail("Cancellation produced a successful snapshot.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class MutatingSnapshotFixtureHasher: LocalModelSHA256Hasher {
    private var mutation: (() throws -> Void)?
    init(_ mutation: @escaping () throws -> Void) { self.mutation = mutation }
    func update(_: UnsafeRawBufferPointer) throws {
        let action = mutation
        mutation = nil
        try action?()
    }
    func finish() throws -> String { String(repeating: "a", count: 64) }
}

private final class SnapshotFixtureHasher: LocalModelSHA256Hasher {
    func update(_: UnsafeRawBufferPointer) throws {}
    func finish() throws -> String { String(repeating: "a", count: 64) }
}
