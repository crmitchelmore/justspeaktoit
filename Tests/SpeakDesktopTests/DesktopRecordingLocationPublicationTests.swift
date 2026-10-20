import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopRecordingLocationPublicationTests: XCTestCase {
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
