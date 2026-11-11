import Foundation
import SpeakCore
import XCTest

/// The phone side of `Tests/Fixtures/watch-capture/wire-v1.json`: the
/// envelope a watch enqueue sends parks an import job, and the import
/// journal's acknowledgements are the ones the watch queue consumes in
/// `WatchCaptureWireContractTests` (SpeakWatchCoreTests).
final class WatchCaptureImportWireContractTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-wire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFixtureEnvelope_parksTheImportJobTheWatchDescribed() throws {
        let fixture = try PhoneWireFixture.load()
        // `WatchCaptureReceiver.session(_:didReceive:)` decodes exactly this.
        let envelope = try XCTUnwrap(WatchCaptureEnvelope.from(metadata: fixture.envelopeMetadata))
        let journal = WatchCaptureImportJournal(directoryURL: directory)

        XCTAssertTrue(journal.parkJobReportingDurability(
            captureID: envelope.id,
            fileExtension: envelope.fileExtension,
            createdAt: envelope.createdAt,
            duration: envelope.duration
        ))

        let job = try XCTUnwrap(journal.pendingJobs().first)
        XCTAssertEqual(job.captureID, fixture.capture.id)
        XCTAssertEqual(job.fileExtension, fixture.capture.fileExtension)
        XCTAssertEqual(job.duration, fixture.capture.duration)
        XCTAssertEqual(job.createdAt, ISO8601DateFormatter().date(from: fixture.capture.createdAt))
    }

    func testImportAcknowledgements_matchTheFixture() throws {
        let fixture = try PhoneWireFixture.load()
        let id = fixture.capture.id
        let journal = WatchCaptureImportJournal(directoryURL: directory)
        journal.parkJob(captureID: id, fileExtension: "m4a", createdAt: Date(), duration: 4.5)

        XCTAssertTrue(journal.completeJobReportingDurability(
            captureID: id,
            acknowledgement: WatchCaptureAckRecord(captureID: id, outcome: .transcribed)
        ))
        let transcribed = try XCTUnwrap(journal.completedAcknowledgement(captureID: id)?.ack.userInfo())
        let failed = try XCTUnwrap(WatchCaptureAckRecord(
            captureID: id, outcome: .failed, message: "Transcription failed: no speech detected."
        ).ack.userInfo())

        XCTAssertEqual(try jsonObject(transcribed), try jsonObject(fixture.transcribedAck))
        XCTAssertEqual(try jsonObject(failed), try jsonObject(fixture.failedAck))
    }
}

/// The JSON object an acknowledgement payload carries, so key order does not matter.
private func jsonObject(_ payload: [String: Any]) throws -> NSDictionary {
    XCTAssertEqual(payload.keys.sorted(), [WatchCaptureAck.userInfoKey])
    let json = try XCTUnwrap(payload[WatchCaptureAck.userInfoKey] as? String)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
}

/// `Tests/Fixtures/watch-capture/wire-v1.json`.
private struct PhoneWireFixture: Decodable {
    let capture: PhoneWireFixtureCapture
    let envelopeMetadata: [String: String]
    let transcribedAck: [String: String]
    let failedAck: [String: String]

    static func load() throws -> PhoneWireFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/watch-capture/wire-v1.json")
        return try JSONDecoder().decode(PhoneWireFixture.self, from: Data(contentsOf: url))
    }
}

private struct PhoneWireFixtureCapture: Decodable {
    let id: UUID
    let createdAt: String
    let duration: TimeInterval
    let fileExtension: String
}
