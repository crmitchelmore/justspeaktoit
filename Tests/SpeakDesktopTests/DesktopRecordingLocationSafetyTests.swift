import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopRecordingLocationSafetyTests: XCTestCase {
    func testLinkedAndReplacedRootsAreRejectedWithoutApplyingThem() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let linked = fixture.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.first)
        do {
            _ = try await store.authorizeLocallySelectedAudioRoot(linked)
            XCTFail("Linked roots must not be registered.")
        } catch {}
        let id = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let record = try await fixture.capture(store, location: id)
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: fixture.first, to: moved)
        try FileManager.default.createDirectory(at: fixture.first, withIntermediateDirectories: false)
        let sentinel = fixture.first.appendingPathComponent("unrelated.wav")
        try Data([99]).write(to: sentinel)
        do {
            _ = try await store.audioURL(for: record)
            XCTFail("An existing registration must reject a replacement root.")
        } catch { XCTAssertTrue(error is DesktopRecordingLocationError) }
        XCTAssertThrowsError(try fixture.store())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([99]))
    }

    func testReplacedPrivateDirectoryOrFileCannotReuseOwnership() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let id = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let record = try await fixture.capture(store, location: id)
        let url = try await store.audioURL(for: record)
        let directory = url.deletingLastPathComponent()
        let moved = fixture.first.appendingPathComponent("old-private")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data([98]).write(to: url)
        do {
            _ = try await store.readAudio(for: record, maximumBytes: 100)
            XCTFail("Replacement private directories cannot inherit claims.")
        } catch { XCTAssertTrue(error is DesktopRecordingLocationError) }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("original"))
        try Data([97]).write(to: url)
        do {
            _ = try await store.audioURL(for: record)
            XCTFail("A replacement file must not inherit the original file identity.")
        } catch { XCTAssertTrue(error is DesktopRecordingLocationError) }
        XCTAssertEqual(try Data(contentsOf: url), Data([97]))
    }

    func testOwnedCleanupCandidatesNeverScanRootsOrAuthorizeDeletion() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let id = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let record = try await fixture.capture(store, location: id)
        let unrelated = fixture.first.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([90]).write(to: unrelated)
        let snapshot = try await store.snapshotSavedAudio()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.entries.first?.localAudio, record.localAudio)
        let outcome = try await store.removeSavedAudio(snapshot)
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        let excluded = try await store.snapshotSavedAudio(excluding: [record.audioFilename])
        XCTAssertTrue(excluded.isEmpty)
        let audio = try await store.audioURL(for: record)
        do {
            try await store.exportTranscriptSnapshot("must not replace audio", to: audio)
            XCTFail("Transcript export must not overwrite registered audio.")
        } catch {}
        do {
            _ = try await store.readAudio(for: record, maximumBytes: 1)
            XCTFail("Strict reads must enforce their byte budget.")
        } catch {}
        do {
            try await store.delete(id: record.id)
            XCTFail("Read evidence must not authorize external-audio deletion or a journal entry.")
        } catch {
            guard case DesktopRecordingLocationError.mutationUnavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.history.appendingPathComponent(".history-deletions").path
        ))
        let recovered = try await store.recoverInterruptedRecordings()
        XCTAssertEqual(recovered.records.count, 1)
        XCTAssertTrue(recovered.records[0].failure?.contains("owned external-audio repair") == true)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([90]))
        let data = try await store.readAudio(for: record, maximumBytes: 1_024)
        XCTAssertEqual(data, PCMWaveWriter.wavData(pcm: Data([1, 2, 3, 4]), sampleRate: 16_000))
        try await store.delete(id: record.id, deleteAudio: false)
        let orphan = try await store.snapshotSavedAudio()
        XCTAssertEqual(orphan.count, 1)
        XCTAssertEqual(orphan.entries.first?.localAudio, record.localAudio)
        XCTAssertEqual(try Data(contentsOf: audio), data)
    }

    func testBackupReadsAndRoundTripsWithoutExportingLocalAuthority() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let id = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let record = try await fixture.capture(store, location: id)
        // A legacy orphan with the same basename must not redirect the locally registered record.
        let legacyCollision = fixture.history.appendingPathComponent(record.audioFilename)
        try Data([7, 8]).write(to: legacyCollision)
        let snapshot = try await store.migrationSnapshot(
            categories: [.history, .recordings], digests: RecordingLocationFixture.digests
        )
        XCTAssertEqual(snapshot.records[.recordings]?.count, 2)
        XCTAssertEqual(snapshot.files.count, 2)
        let archive = try MigrationTestArchive.export(
            snapshot, digests: RecordingLocationFixture.digests, stagingRoot: fixture.history
        )
        let restored = try MigrationTestArchive.read(
            archive, digests: RecordingLocationFixture.digests, stagingRoot: fixture.history
        )
        let audio = try XCTUnwrap(restored.records[.recordings]?.first { $0.id == record.id.uuidString })
        let imported = try DesktopMigrationHistory.record(audio, category: .recordings, audioFilename: "installed.wav")
        XCTAssertNil(imported.localAudio)
        XCTAssertEqual(imported.id, record.id)
        let bytes = try Data(contentsOf: XCTUnwrap(restored.files[XCTUnwrap(audio.file)]))
        XCTAssertEqual(bytes, PCMWaveWriter.wavData(pcm: Data([1, 2, 3, 4]), sampleRate: 16_000))
        XCTAssertEqual(try Data(contentsOf: legacyCollision), Data([7, 8]))
    }

    func testFailedCapturePersistenceDiscardsOnlyOwnedUnpublishedFile() async throws {
        #if !os(Linux)
        throw XCTSkip("Requires qualified Linux capture.")
        #else
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let id = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let unrelated = fixture.first.appendingPathComponent("unrelated.wav")
        try Data([91]).write(to: unrelated)
        fixture.memory.failure = .recording
        do {
            _ = try await store.createLocallyAuthorizedCapture(at: id)
            XCTFail("Failed immutable ownership persistence must not return a usable capture.")
        } catch { XCTAssertTrue(error is RecordingLocationMemoryPersistence.Failure) }
        let folders = try FileManager.default.contentsOfDirectory(at: fixture.first, includingPropertiesForKeys: nil)
            .filter { $0 != unrelated }
        XCTAssertEqual(folders.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: XCTUnwrap(folders.first).path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([91]))
        #endif
    }
}
