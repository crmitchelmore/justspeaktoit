import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopRecordingLocationPublicationTests: XCTestCase {
    func testCommittedRegistrationFailure_ReusesDurableIDAcrossRetryAndRestart() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let id = UUID()
        fixture.memory.didAppendRegistration = {
            throw DesktopRecordingRegistryWriteFailure(
                primaryError: CancellationError(), cleanupError: nil, effect: .published
            )
        }
        do {
            _ = try await store.authorizeLocallySelectedAudioRoot(fixture.first, id: id)
            XCTFail("A committed failure must still be reported.")
        } catch {
            guard let failure = error as? DesktopRecordingRegistryWriteFailure, case .published = failure.effect else {
                return XCTFail("Expected an explicit committed publication failure, received \(error)")
            }
            XCTAssertTrue(failure.primaryError is CancellationError)
        }
        let root = await store.audioLocationRoot(id)
        XCTAssertEqual(root, fixture.first)
        fixture.memory.didAppendRegistration = nil
        let retried = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        XCTAssertEqual(retried, id)
        let restarted = try fixture.store()
        let restored = try await restarted.authorizeLocallySelectedAudioRoot(fixture.first)
        XCTAssertEqual(restored, id)
        XCTAssertEqual(try fixture.memory.loadVerified().registrations.count, 1)
    }

    func testRepeatedSelection_ReusesOnlyTheVerifiedDirectoryIdentity() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        var locations = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        let id = try locations.authorizeLocallySelectedRoot(fixture.first)
        XCTAssertEqual(try locations.authorizeLocallySelectedRoot(fixture.first), id)
        let moved = fixture.root.appendingPathComponent("original-root")
        try FileManager.default.moveItem(at: fixture.first, to: moved)
        try FileManager.default.createDirectory(at: fixture.first, withIntermediateDirectories: false)
        XCTAssertThrowsError(try locations.authorizeLocallySelectedRoot(fixture.first)) {
            guard case DesktopRecordingLocationError.changedLocation = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try fixture.memory.loadVerified().registrations.count, 1)
    }

    func testPostAppendValidationFailure_KeepsThePublishedRegistrationReserved() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        var locations = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        let id = UUID()
        let moved = fixture.root.appendingPathComponent("original-root")
        fixture.memory.didAppendRegistration = {
            try FileManager.default.moveItem(at: fixture.first, to: moved)
            try FileManager.default.createDirectory(at: fixture.first, withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try locations.authorizeLocallySelectedRoot(fixture.first, id: id))
        XCTAssertEqual(locations.registeredRoot(id), fixture.first)
        fixture.memory.didAppendRegistration = nil
        XCTAssertThrowsError(try locations.authorizeLocallySelectedRoot(fixture.first))
        XCTAssertEqual(try fixture.memory.loadVerified().registrations.count, 1)
    }

    func testCancellationAfterOwnershipPublication_DoesNotDiscardTheCommittedCapture() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        var locations = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        let location = try locations.authorizeLocallySelectedRoot(fixture.first)
        let writer = RecordingCleanupWriter()
        var cancelled = false
        fixture.memory.didAppendRecording = { cancelled = true }
        let capture = try locations.createCapture(at: location, using: writer.factory, checkCancellation: {
            if cancelled { throw CancellationError() }
        })
        XCTAssertTrue(cancelled)
        XCTAssertThrowsError(try capture.file.discard())
        let pcm = try PCMRecordingFile(ownedFile: capture.file, sampleRate: 16_000)
        try pcm.append(Data([1, 2, 3, 4]))
        _ = try pcm.finish()
        let record = DesktopRecordingStore.Record(capture: capture, modelIdentifier: "fixture")
        let restarted = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        XCTAssertEqual(try restarted.resolve(record), writer.url)
        XCTAssertEqual(writer.removals, 0)
        XCTAssertEqual(writer.closes, 1)
    }

    func testCommittedAppendFailure_PreservesAudioAndOwnershipAcrossRestart() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        var locations = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        let location = try locations.authorizeLocallySelectedRoot(fixture.first)
        let writer = RecordingCleanupWriter()
        let id = UUID()
        fixture.memory.didAppendRecording = {
            throw DesktopRecordingRegistryWriteFailure(
                primaryError: CancellationError(), cleanupError: nil, effect: .published
            )
        }
        XCTAssertThrowsError(try locations.createCapture(at: location, recordingID: id, using: writer.factory)) {
            guard let failure = $0 as? DesktopRecordingRegistryWriteFailure, case .published = failure.effect else {
                return XCTFail("Expected an explicit committed publication failure, received \($0)")
            }
            XCTAssertTrue(failure.primaryError is CancellationError)
        }
        XCTAssertEqual(writer.removals, 0)
        XCTAssertEqual(writer.closes, 1)
        XCTAssertEqual(try Data(contentsOf: writer.url), writer.bytes)
        let ownership = try XCTUnwrap(fixture.memory.loadVerified().recordings.first)
        var record = DesktopRecordingStore.Record(
            id: id, audioFilename: writer.url.lastPathComponent, modelIdentifier: "fixture"
        )
        record.localAudio = ownership.reference
        XCTAssertEqual(try locations.resolve(record), writer.url)
        let restarted = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        XCTAssertEqual(try restarted.resolve(record), writer.url)
        XCTAssertThrowsError(try locations.createCapture(at: location, recordingID: id, using: writer.factory))
        XCTAssertEqual(writer.creations, 1)
    }

    func testCommittedCaptureFailure_StorePreservesThePublishedIdentityBeforeRestart() async throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        let store = try fixture.store()
        let location = try await store.authorizeLocallySelectedAudioRoot(fixture.first)
        let writer = RecordingCleanupWriter()
        let id = UUID()
        fixture.memory.didAppendRecording = {
            throw DesktopRecordingRegistryWriteFailure(
                primaryError: CancellationError(), cleanupError: nil, effect: .published
            )
        }
        do {
            _ = try await store.createLocallyAuthorizedCapture(at: location, recordingID: id, using: writer.factory)
            XCTFail("A committed failure must still be reported.")
        } catch {
            guard let failure = error as? DesktopRecordingRegistryWriteFailure, case .published = failure.effect else {
                return XCTFail("Expected a committed capture failure, received \(error)")
            }
        }
        let publishedURL = writer.url
        fixture.memory.didAppendRecording = nil
        do {
            _ = try await store.createLocallyAuthorizedCapture(at: location, recordingID: id, using: writer.factory)
            XCTFail("The store must reserve the published capture identity.")
        } catch {
            guard case DesktopRecordingLocationError.duplicateIdentity = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(writer.creations, 1)
        XCTAssertEqual(try Data(contentsOf: publishedURL), writer.bytes)
    }

    func testPCMInitializationFailureAfterPublication_KeepsRegisteredRecoveryAudio() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        var locations = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        let location = try locations.authorizeLocallySelectedRoot(fixture.first)
        let writer = RecordingCleanupWriter()
        let capture = try locations.createCapture(at: location, using: writer.factory)
        writer.writeError = RecordingCleanupInjectedError.append("Synthetic PCM header failure")
        XCTAssertThrowsError(try PCMRecordingFile(ownedFile: capture.file, sampleRate: 16_000))
        XCTAssertEqual(writer.removals, 0)
        XCTAssertEqual(writer.closes, 1)
        XCTAssertEqual(try Data(contentsOf: writer.url), writer.bytes)
        let record = DesktopRecordingStore.Record(capture: capture, modelIdentifier: "fixture")
        let restarted = try DesktopRecordingLocations(historyDirectory: fixture.history, persistence: fixture.memory)
        XCTAssertEqual(try restarted.resolve(record), writer.url)
    }
}
