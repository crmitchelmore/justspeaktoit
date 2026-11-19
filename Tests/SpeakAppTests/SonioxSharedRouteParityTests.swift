import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// The former `SonioxLiveController` behaviour, proven on the shared path.
@MainActor
final class SonioxSharedRouteParityTests: XCTestCase {
    private static let model = "soniox/stt-rt-v6-streaming"

    func testCumulativeRevisionsReplaceTheDisplayWithoutDuplicatingWords() async throws {
        let fixture = try makeFixture()
        try await start(fixture)
        fixture.socket.emit(#"{"tokens":[{"text":"Hello","is_final":true},{"text":" wor","is_final":false}]}"#)
        fixture.socket.emit(#"{"tokens":[{"text":" world","is_final":false}]}"#)
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.partials.last, "Hello world")
        XCTAssertFalse(fixture.delegate.partials.contains { $0.contains("Hello Hello") })
    }

    func testFinishDrainsAudioFinalizesThenAdoptsTheWholeConfirmedResult() async throws {
        let fixture = try makeFixture(grace: 0.1)
        try await start(fixture)
        XCTAssertEqual(fixture.controller.stopCompletionTimeout, 10.1, accuracy: 0.001, "Grace extends the watchdog")
        fixture.socket.emit(#"{"tokens":[{"text":"Hello","is_final":true},{"text":" draft","is_final":false}]}"#)
        let pcm = Data(repeating: 1, count: 2_730)
        fixture.send(pcm)
        let socket = fixture.socket
        let stopping = await fixture.beginStop {
            socket.completeSends()
            return socket.text.last == ""
        }
        XCTAssertEqual(socket.binary, [pcm], "Tap-sized PCM goes out unframed, as on iOS and Windows")
        XCTAssertEqual(Array(socket.text.suffix(2)), [#"{"type":"finalize"}"#, ""])
        socket.completeSends()
        socket.emit(#"{"tokens":[{"text":" world.","is_final":true}],"finished":true}"#)
        await stopping.value

        let result = try XCTUnwrap(fixture.delegate.results.last)
        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertEqual(result.modelIdentifier, Self.model)
        XCTAssertNotNil(result.cost, "History keeps a Soniox cost estimate")
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testServerFailureDuringFinishKeepsTheDraftAndNeverReportsSuccess() async throws {
        let fixture = try makeFixture()
        try await start(fixture)
        fixture.socket.emit(#"{"tokens":[{"text":"Draft only","is_final":false}]}"#)
        let socket = fixture.socket
        let stopping = await fixture.beginStop {
            socket.completeSends()
            return socket.text.last == ""
        }
        socket.emit(#"{"error_code":500,"error_message":"synthetic failure"}"#)
        await stopping.value
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
        XCTAssertEqual(fixture.delegate.partials.last, "Draft only")
    }

    func testExplicitLocaleBecomesALanguageHintAndAutomaticOmitsIt() async throws {
        for language in ["fr_FR", nil] as [String?] {
            let fixture = try makeFixture(language: language)
            try await start(fixture)
            let json = try XCTUnwrap(fixture.socket.text.first)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            )
            XCTAssertEqual(payload["model"] as? String, "stt-rt-v6")
            XCTAssertEqual(payload["sample_rate"] as? Int, 16_000)
            XCTAssertEqual(payload["language_hints"] as? [String], language.map { _ in ["fr"] })
        }
    }

    private func start(_ fixture: SharedClientParityFixture) async throws {
        try await fixture.start()
        fixture.socket.completeSends()
    }

    private func makeFixture(language: String? = nil, grace: TimeInterval = 0) throws -> SharedClientParityFixture {
        try SharedClientParityFixture(model: Self.model, language: language, stopGrace: grace) { context in
            SonioxLiveClient(
                apiKey: "synthetic", model: context.route.apiModelName, language: context.language,
                sampleRate: context.route.sampleRate,
                makeConnection: { [socket = context.socket] _ in socket },
                schedule: { [clock = context.clock] in clock.schedule($0, action: $1) }
            )
        }
    }
}
