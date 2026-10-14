import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopRecordingAudioCleanupTests: XCTestCase {
    func testAudioExtensionPolicy_ProtectsMetadataAndIncludesImportedOrphan() async throws {
        XCTAssertEqual(RecordingAudioFormats.macArchiveExtensions, ["aac", "caf", "m4a", "m4b", "mp3", "wav"])
        XCTAssertTrue(RecordingAudioFormats.importExtensions.isSubset(of: RecordingAudioFormats.archiveExtensions))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-types-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root)
        let id = UUID()
        let record = DesktopRecordingStore.Record(
            id: id, audioFilename: id.uuidString + ".json", modelIdentifier: "test"
        )
        try await store.save(record)
        let metadata = root.appendingPathComponent(record.audioFilename)
        let before = try Data(contentsOf: metadata)
        let imported = root.appendingPathComponent(UUID().uuidString + ".mp3")
        try Data([1]).write(to: imported)
        let snapshot = try await store.snapshotSavedAudio()
        XCTAssertEqual(snapshot.count, 1)
        let outcome = try await store.removeSavedAudio(snapshot)
        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(try Data(contentsOf: metadata), before)
    }

    func testCancellation_KeepsUnadmittedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root)
        let file = root.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1]).write(to: file)
        let snapshot = try await store.snapshotSavedAudio()
        let outcome = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.removeSavedAudio(snapshot)
        }.value
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
    }

    func testCleanup_PreservesHistoryAndRemovesRetainedKeptAndOrphanAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-cleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root)
        let retained = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: UUID().uuidString + ".wav", modelIdentifier: "test"
        )
        let kept = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: UUID().uuidString + ".wav", modelIdentifier: "test"
        )
        try await store.save(retained)
        try await store.save(kept)
        let orphan = UUID().uuidString + ".wav"
        for name in [retained.audioFilename, kept.audioFilename, orphan] {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
        }
        try await store.delete(id: kept.id, deleteAudio: false)
        let metadata = root.appendingPathComponent(retained.id.uuidString + ".json")
        let journal = root.appendingPathComponent(".history-deletions")
        let metadataBefore = try Data(contentsOf: metadata)
        let journalBefore = try Data(contentsOf: journal)
        let snapshot = try await store.snapshotSavedAudio()
        XCTAssertEqual(snapshot.count, 3)
        let outcome = try await store.removeSavedAudio(snapshot)
        XCTAssertEqual(outcome.removed, 3)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: metadata), metadataBefore)
        XCTAssertEqual(try Data(contentsOf: journal), journalBefore)
        let records = try await store.records()
        XCTAssertEqual(records.map(\.id), [retained.id])
    }

    func testFrozenSnapshot_ExcludesActiveNewForeignAndStagedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-frozen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root)
        let saved = UUID().uuidString + ".wav"
        let active = UUID().uuidString + ".wav"
        let late = UUID().uuidString + ".wav"
        let stage = root.appendingPathComponent("Voice")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let stagedAudio = stage.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1]).write(to: stagedAudio)
        for name in [saved, active, "foreign.wav", "notes.txt"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        let snapshot = try await store.snapshotSavedAudio(excluding: [active])
        try Data([2]).write(to: root.appendingPathComponent(late))
        let outcome = try await store.removeSavedAudio(snapshot)
        XCTAssertEqual(outcome.removed, 1)
        for name in [active, late, "foreign.wav", "notes.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedAudio.path))
    }

    func testChangedAudio_IsKeptAndOtherConfirmedFilesStillRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-replaced-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root)
        let changed = root.appendingPathComponent(UUID().uuidString + ".wav")
        let unchanged = root.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1]).write(to: changed)
        try Data([1]).write(to: unchanged)
        let snapshot = try await store.snapshotSavedAudio()
        try Data([2, 3]).write(to: changed)
        let outcome = try await store.removeSavedAudio(snapshot)
        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: changed), Data([2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unchanged.path))
    }

    func testLinkedAudio_RefusesSnapshotWithoutTouchingItsTarget() async throws {
        #if os(Windows)
        throw XCTSkip("Creating symbolic links requires a separately authorized Windows capability.")
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-linked-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root)
        let target = root.appendingPathComponent("foreign.txt")
        try Data([4]).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(UUID().uuidString + ".wav"), withDestinationURL: target
        )
        do {
            _ = try await store.snapshotSavedAudio()
            XCTFail("Linked audio must not become deletion authority")
        } catch {
            XCTAssertEqual(try Data(contentsOf: target), Data([4]))
        }
        #endif
    }

    func testMissingAudio_IsIdempotentAndForeignStoreCannotApplySnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-missing-\(UUID())")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("audio-other-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let store = try DesktopRecordingStore(directory: root)
        let foreign = try DesktopRecordingStore(directory: other)
        let file = root.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1]).write(to: file)
        let snapshot = try await store.snapshotSavedAudio()
        do {
            _ = try await foreign.removeSavedAudio(snapshot)
            XCTFail("A snapshot must not transfer to another directory")
        } catch DesktopRecordingAudioCleanupError.changedDirectory {}
        try FileManager.default.removeItem(at: file)
        let outcome = try await store.removeSavedAudio(snapshot)
        XCTAssertEqual(outcome.missing, 1)
        XCTAssertTrue(outcome.failures.isEmpty)
    }
}
