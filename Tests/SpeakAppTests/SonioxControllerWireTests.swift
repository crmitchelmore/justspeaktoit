import Foundation
import XCTest
@testable import SpeakApp

/// Production adapter over the real shared client with an injected socket.
final class SonioxControllerWireTests: XCTestCase {
    func testPrerollWaitsForHandshakeThenSendsConfigurationBeforeOrderedPCM() {
        let fixture = SonioxControllerFixture()
        let first = Data(repeating: 1, count: SonioxControllerClient.preferredChunkBytes)
        let second = Data(repeating: 2, count: SonioxControllerClient.preferredChunkBytes)
        fixture.adapter.sendAudio(first)
        fixture.start()
        fixture.adapter.sendAudio(second)
        XCTAssertTrue(fixture.socket.controls.isEmpty)
        XCTAssertTrue(fixture.socket.binary.isEmpty)
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.controls.count, 1)
        XCTAssertTrue(fixture.socket.binary.isEmpty)
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, [first])
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, [first, second])
        fixture.adapter.cancel()
        fixture.adapter.sendAudio(first)
        XCTAssertEqual(fixture.socket.binary, [first, second])
        XCTAssertTrue(fixture.socket.isCancelled)
    }

    func testExplicitLocaleAndAutomaticLanguageKeepExistingWireSemantics() throws {
        for language in ["fr_FR", nil] as [String?] {
            let fixture = SonioxControllerFixture(language: language)
            fixture.start()
            fixture.ready()
            let json = try XCTUnwrap(fixture.socket.controls.first)
            let data = try XCTUnwrap(json.data(using: .utf8))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(payload["model"] as? String, "stt-rt-v5")
            XCTAssertEqual(payload["sample_rate"] as? Int, 16_000)
            XCTAssertEqual(payload["num_channels"] as? Int, 1)
            if language == nil {
                XCTAssertNil(payload["language_hints"])
            } else {
                XCTAssertEqual(payload["language_hints"] as? [String], ["fr"])
            }
            fixture.adapter.cancel()
        }
    }

    func testFinishDrainsAudioThenAdoptsWholeConfirmedResultWithoutWaitingForDeadline() async {
        let fixture = SonioxControllerFixture()
        fixture.start()
        fixture.ready()
        fixture.socket.emit(#"{"tokens":[{"text":"Hello","is_final":true},{"text":" draft","is_final":false}]}"#)
        XCTAssertEqual(fixture.adapter.snapshot.text, "Hello draft")
        let pcm = Data(repeating: 1, count: 3_200)
        fixture.adapter.sendAudio(pcm)
        let finished = Task { await fixture.adapter.finishAndWait() }
        await self.waitUntil { fixture.clock.delays.contains(SonioxControllerClient.finishTimeout) }
        XCTAssertEqual(fixture.socket.binary, [pcm])
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, [pcm, Data()])
        fixture.socket.completeSend()
        fixture.socket.emit(#"{"tokens":[{"text":" world.","is_final":true}],"finished":true}"#)
        let snapshot = await finished.value
        XCTAssertEqual(snapshot.text, "Hello world.")
        XCTAssertEqual(snapshot.confirmedText, snapshot.text)
        XCTAssertNil(snapshot.error)
        XCTAssertTrue(fixture.socket.isCancelled)
        // No deadline was fired: receipt of finished is sufficient.
        fixture.clock.fire(SonioxControllerClient.finishTimeout)
        XCTAssertNil(fixture.adapter.snapshot.error)
    }

    func testMacDeadlineFailsVisiblyAndKeepsConfirmedTextBeforeReturning() async {
        let fixture = SonioxControllerFixture()
        fixture.start()
        fixture.ready()
        fixture.socket.emit(
            #"{"tokens":[{"text":"Confirmed.","is_final":true},{"text":" trailing draft","is_final":false}]}"#
        )
        let finished = Task { await fixture.adapter.finishAndWait() }
        await self.waitUntil { fixture.clock.delays.contains(3.5) }
        XCTAssertFalse(fixture.clock.delays.contains(8))
        fixture.socket.completeSend()
        fixture.clock.fire(3.5)
        let snapshot = await finished.value
        XCTAssertEqual(snapshot.text, "Confirmed. trailing draft")
        XCTAssertEqual(snapshot.confirmedText, "Confirmed.")
        XCTAssertNotNil(snapshot.error)
        XCTAssertTrue(fixture.socket.isCancelled)
    }

    func testServerFailureDuringFinishCannotBecomeHealthyCompletion() async {
        let fixture = SonioxControllerFixture()
        fixture.start()
        fixture.ready()
        fixture.socket.emit(#"{"tokens":[{"text":"Draft only","is_final":false}]}"#)
        let finished = Task { await fixture.adapter.finishAndWait() }
        await self.waitUntil { fixture.clock.delays.contains(3.5) }
        fixture.socket.emit(#"{"error_code":500,"error_message":"synthetic failure"}"#)
        let snapshot = await finished.value
        XCTAssertEqual(snapshot.text, "Draft only")
        XCTAssertNotNil(snapshot.error)
        XCTAssertTrue(fixture.socket.isCancelled)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Shared client did not enter finish before the test deadline")
    }
}
