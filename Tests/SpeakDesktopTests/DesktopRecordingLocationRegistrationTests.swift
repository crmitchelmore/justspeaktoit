import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopRecordingLocationProofTests: XCTestCase {
    func testAppendAndRemoveFailurePreserveTypedCausesWithoutDisplayingValues() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        var locations = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        let id = try locations.authorizeLocallySelectedRoot(fixture.first)
        let unrelated = fixture.first.appendingPathComponent("unrelated.wav")
        try Data([92]).write(to: unrelated)
        let primary = RecordingCleanupInjectedError.append("private append value: " + fixture.history.path)
        fixture.memory.recordingError = primary
        let writer = RecordingCleanupWriter()
        XCTAssertThrowsError(try locations.createCapture(at: id, using: writer.factory)) { error in
            guard let failure = error as? DesktopRecordingLocationCleanupFailure else {
                return XCTFail("Expected typed location cleanup failure.")
            }
            XCTAssertEqual(failure.primaryError as? RecordingCleanupInjectedError, primary)
            XCTAssertEqual(
                failure.cleanupError as? RecordingCleanupInjectedError, .remove(writer.url.path)
            )
            XCTAssertEqual(
                failure.localizedDescription,
                "Recording audio allocation failed, and unpublished capture cleanup could not be completed."
            )
            XCTAssertFalse(failure.localizedDescription.contains(fixture.root.path))
            XCTAssertFalse(failure.localizedDescription.contains("private append value"))
            XCTAssertEqual(String(describing: failure), failure.localizedDescription)
            XCTAssertEqual(String(reflecting: failure), failure.localizedDescription)
        }
        try assertFailedCleanup(writer, unrelated: unrelated)
        XCTAssertTrue(locations.recordings.isEmpty)
        XCTAssertTrue(try fixture.memory.loadVerified().recordings.isEmpty)
    }

    func testCancellationAndRemoveFailurePreserveTypedCausesAndCloseOnce() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        var locations = try DesktopRecordingLocations(
            historyDirectory: fixture.history, persistence: fixture.memory
        )
        let id = try locations.authorizeLocallySelectedRoot(fixture.first)
        let unrelated = fixture.first.appendingPathComponent("unrelated.wav")
        try Data([92]).write(to: unrelated)
        let writer = RecordingCleanupWriter()
        var checks = 0
        XCTAssertThrowsError(try locations.createCapture(
            at: id, using: writer.factory, checkCancellation: {
                checks += 1
                if checks == 4 { throw CancellationError() }
            }
        )) { error in
            guard let failure = error as? DesktopRecordingLocationCleanupFailure else {
                return XCTFail("Expected typed location cleanup failure.")
            }
            XCTAssertTrue(failure.primaryError is CancellationError)
            XCTAssertEqual(
                failure.cleanupError as? RecordingCleanupInjectedError, .remove(writer.url.path)
            )
            XCTAssertFalse(failure.localizedDescription.contains(fixture.root.path))
        }
        XCTAssertEqual(checks, 4)
        try assertFailedCleanup(writer, unrelated: unrelated)
        XCTAssertTrue(locations.recordings.isEmpty)
        XCTAssertTrue(try fixture.memory.loadVerified().recordings.isEmpty)
    }

    private func assertFailedCleanup(_ writer: RecordingCleanupWriter, unrelated: URL) throws {
        XCTAssertEqual(writer.creations, 1)
        XCTAssertEqual(writer.removals, 1)
        XCTAssertEqual(writer.closes, 1)
        XCTAssertEqual(try Data(contentsOf: writer.url), writer.bytes)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([92]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: writer.url.deletingLastPathComponent().path
        ), [writer.url.lastPathComponent])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: unrelated.deletingLastPathComponent().path
        ).count, 2)
    }

    func testMalformedOrDuplicatedVerifiedRowsAreNotApplied() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        var locations = try DesktopRecordingLocations(
            historyDirectory: fixture.history, persistence: fixture.memory
        )
        _ = try locations.authorizeLocallySelectedRoot(fixture.first)
        let state = try fixture.memory.loadVerified()
        let registration = try XCTUnwrap(state.registrations.first)
        fixture.memory.overrideState = .init(verifiedRegistrations: [registration, registration])
        XCTAssertThrowsError(try DesktopRecordingLocations(
            historyDirectory: fixture.history, persistence: fixture.memory
        ))
        let malformed = DesktopRecordingLocationRegistration(
            id: registration.id, root: try XCTUnwrap(URL(string: "https://example.invalid/foreign")),
            history: registration.history, historyIdentity: registration.historyIdentity,
            rootIdentity: registration.rootIdentity
        )
        fixture.memory.overrideState = .init(verifiedRegistrations: [malformed])
        XCTAssertThrowsError(try DesktopRecordingLocations(
            historyDirectory: fixture.history, persistence: fixture.memory
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.first.path).isEmpty)
    }

    func testMalformedRestoredClaimsAndSyncedCopiesNeverGrantLocalAccess() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let id = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let original = try await fixture.capture(store, location: id)
        let state = try fixture.memory.loadVerified()
        let ownership = try XCTUnwrap(state.recordings.first)
        let malformed = DesktopRecordingLocationOwnership(
            recordingID: ownership.recordingID,
            reference: .init(locationID: id, relativePath: fixture.first.path),
            directoryIdentity: ownership.directoryIdentity, fileIdentity: ownership.fileIdentity
        )
        fixture.memory.overrideState = .init(
            verifiedRegistrations: state.registrations, verifiedRecordings: [malformed]
        )
        XCTAssertThrowsError(try fixture.store())
        fixture.memory.overrideState = .init(
            verifiedRegistrations: state.registrations, verifiedRecordings: [ownership, ownership]
        )
        XCTAssertThrowsError(try fixture.store())
        var synced = original
        synced.originPlatform = "macos"
        do {
            _ = try await store.audioURL(for: synced)
            XCTFail("Origin-platform semantics must not grant local audio to synced copies.")
        } catch {
            guard case DesktopRecordingLocationError.invalidReference = error else { return XCTFail("\(error)") }
        }
    }

    func testCancellationBeforeImmutableAppendCleansOnlyUnpublishedAudio() throws {
        #if !os(Linux)
        throw XCTSkip("Requires qualified Linux held creation.")
        #else
        for cancellationCheck in [3, 4] {
            let fixture = try RecordingLocationFixture()
            defer { try? fixture.clean() }
            var locations = try DesktopRecordingLocations(
                historyDirectory: fixture.history, persistence: fixture.memory
            )
            let id = try locations.authorizeLocallySelectedRoot(fixture.first)
            let unrelated = fixture.first.appendingPathComponent("unrelated.wav")
            try Data([92]).write(to: unrelated)
            var checks = 0
            XCTAssertThrowsError(try locations.createCapture(at: id, checkCancellation: {
                checks += 1
                if checks == cancellationCheck { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, cancellationCheck)
            let directories = try FileManager.default.contentsOfDirectory(
                at: fixture.first, includingPropertiesForKeys: nil
            ).filter { $0 != unrelated }
            XCTAssertEqual(directories.count, 1)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(
                atPath: XCTUnwrap(directories.first).path
            ).isEmpty)
            XCTAssertEqual(try Data(contentsOf: unrelated), Data([92]))
            let restored = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
            XCTAssertTrue(restored.recordings.isEmpty)
        }
        #endif
    }

    func testMixedCaseMetadataCannotJournalExternalAudioDeletion() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let location = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let id = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        let original = try await fixture.capture(store, location: location, id: id)
        let legacy = DesktopRecordingStore.Record(
            id: id, audioFilename: original.audioFilename, modelIdentifier: "legacy"
        )
        try JSONEncoder().encode(legacy).write(
            to: fixture.history.appendingPathComponent(id.uuidString.lowercased() + ".json")
        )
        do {
            try await store.delete(id: id)
            XCTFail("Every metadata variant must pass admission before journaling.")
        } catch {
            guard case DesktopRecordingLocationError.mutationUnavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.history.appendingPathComponent(".history-deletions").path
        ))
        let data = try await store.readAudio(for: original, maximumBytes: 1_024)
        XCTAssertFalse(data.isEmpty)
    }
}
