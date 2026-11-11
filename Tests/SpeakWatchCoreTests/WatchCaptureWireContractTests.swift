import Foundation
import SpeakWatchCore
import XCTest

/// The watch side of `Tests/Fixtures/watch-capture/wire-v1.json`: a real
/// enqueue produces the fixture's envelope, and the phone's acknowledgements
/// in the fixture drive the queue. `WatchCaptureImportWireContractTests`
/// (SpeakCoreTests) checks the phone side against the same file.
@MainActor
final class WatchCaptureWireContractTests: XCTestCase {
    /// WatchConnectivity only carries property lists, so every payload makes
    /// the trip a real transfer would.
    private final class PropertyListTransport: WatchCaptureTransport {
        var isActivated = true
        var sentMetadata: [[String: Any]] = []

        func hasOutstandingTransfer(for id: UUID) -> Bool { false }

        func transferFile(_ url: URL, envelope: WatchCaptureEnvelope) {
            guard let metadata = envelope.metadata(), let sent = try? roundTrip(metadata) else { return }
            sentMetadata.append(sent)
        }
    }

    private var files: Set<URL> = []

    private func makeQueue(_ transport: PropertyListTransport) -> WatchCaptureQueue {
        WatchCaptureQueue(
            captures: [],
            transport: transport,
            audioURL: { URL(fileURLWithPath: "/captures/\($0.uuidString).m4a") },
            fileExists: { [unowned self] in self.files.contains($0) },
            removeFile: { [unowned self] in self.files.remove($0) },
            persist: { _ in true },
            scheduleRetry: { _, _ in }
        )
    }

    private func enqueueFixtureCapture(
        _ fixture: WatchWireFixture,
        transport: PropertyListTransport
    ) throws -> WatchCaptureQueue {
        let queue = makeQueue(transport)
        files.insert(URL(fileURLWithPath: "/captures/\(fixture.capture.id.uuidString).m4a"))
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: fixture.capture.createdAt))
        XCTAssertTrue(queue.enqueue(id: fixture.capture.id, createdAt: createdAt, duration: fixture.capture.duration))
        return queue
    }

    func testEnqueue_sendsTheFixtureEnvelope() throws {
        let fixture = try WatchWireFixture.load()
        let transport = PropertyListTransport()

        _ = try enqueueFixtureCapture(fixture, transport: transport)

        let sent = try XCTUnwrap(transport.sentMetadata.first as? [String: String])
        XCTAssertEqual(sent.keys.sorted(), [WatchCaptureEnvelope.metadataKey])
        XCTAssertEqual(
            try jsonObject(sent, key: WatchCaptureEnvelope.metadataKey),
            try jsonObject(fixture.envelopeMetadata, key: WatchCaptureEnvelope.metadataKey)
        )
    }

    func testPhoneTranscribedAck_releasesTheWatchAudio() throws {
        let fixture = try WatchWireFixture.load()
        let queue = try enqueueFixtureCapture(fixture, transport: PropertyListTransport())
        queue.transferFinished(id: fixture.capture.id, error: nil)

        let ack = try XCTUnwrap(WatchCaptureAck.from(userInfo: roundTrip(fixture.transcribedAck)))
        queue.handleAck(ack)

        XCTAssertEqual(queue.captures.first?.status, .transcribed)
        XCTAssertTrue(files.isEmpty, "Audio is released only by the success acknowledgement")
    }

    func testPhoneFailedAck_keepsTheAudioAndShowsTheReason() throws {
        let fixture = try WatchWireFixture.load()
        let queue = try enqueueFixtureCapture(fixture, transport: PropertyListTransport())
        queue.transferFinished(id: fixture.capture.id, error: nil)

        let ack = try XCTUnwrap(WatchCaptureAck.from(userInfo: roundTrip(fixture.failedAck)))
        queue.handleAck(ack)

        XCTAssertEqual(queue.captures.first?.status, .failed)
        XCTAssertEqual(queue.captures.first?.message, "Transcription failed: no speech detected.")
        XCTAssertEqual(files.count, 1)
    }
}

private func roundTrip(_ payload: [String: Any]) throws -> [String: Any] {
    let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
    let decoded = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(decoded as? [String: Any])
}

/// The JSON object a payload's string carries, so key order does not matter.
private func jsonObject(_ payload: [String: String], key: String) throws -> NSDictionary {
    let json = try XCTUnwrap(payload[key])
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
}

/// `Tests/Fixtures/watch-capture/wire-v1.json`.
private struct WatchWireFixture: Decodable {
    let capture: WatchWireFixtureCapture
    let envelopeMetadata: [String: String]
    let transcribedAck: [String: String]
    let failedAck: [String: String]

    static func load() throws -> WatchWireFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/watch-capture/wire-v1.json")
        return try JSONDecoder().decode(WatchWireFixture.self, from: Data(contentsOf: url))
    }
}

private struct WatchWireFixtureCapture: Decodable {
    let id: UUID
    let createdAt: String
    let duration: TimeInterval
    let fileExtension: String
}
