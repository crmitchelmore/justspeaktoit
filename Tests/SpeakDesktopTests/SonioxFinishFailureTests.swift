import Foundation
import XCTest
@testable import SpeakCore

final class SonioxFinishFailureTests: XCTestCase {
    func testProviderErrorAfterEndOfStreamIsReportedAndTextRetained() async {
        for code in [401, 503] {
            let fixture = SonioxLiveFixture()
            fixture.start()
            fixture.becomeReady()
            fixture.socket.emit(#"{"tokens":[{"text":"Saved.","is_final":true}]}"#)
            let finish = Task { await fixture.client.finishAndWait() }
            await fixture.awaitEndOfStream()
            fixture.socket.completeSend()
            fixture.socket.emit("{\"error_code\":\(code),\"error_message\":\"service failed\"}")
            let text = await finish.value
            XCTAssertEqual(text, "Saved.")
            XCTAssertEqual(fixture.events.errors.count, 1)
        }
    }

    func testMissingFinishedEndsTheFinishAtItsDeadlineWithWhatItHas() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(#"{"tokens":[{"text":"Kept.","is_final":true}]}"#)
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(SonioxLiveClient.finishDeadline)
        await fixture.completeFinalize()
        fixture.socket.completeSend() // end-of-stream
        fixture.clock.fire(SonioxLiveClient.finishDeadline)
        let text = await finish.value
        XCTAssertEqual(text, "Kept.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testEndOfStreamSendFailureIsNotSuccess() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.awaitEndOfStream()
        fixture.socket.completeSend(URLError(.networkConnectionLost))
        _ = await finish.value
        XCTAssertEqual(fixture.events.errors.count, 1)
    }

    func testFinishedBeforeEndOfStreamSendCompletionStillSucceeds() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.onSend = { message in
            if case .text(SonioxLiveFixture.finalize) = message {
                DispatchQueue.global().async { fixture.socket.completeSend() }
            }
            if case .binary(let data) = message, data.isEmpty {
                fixture.socket.emit(#"{"tokens":[{"text":"Complete.","is_final":true}],"finished":true}"#)
            }
        }
        let text = await fixture.client.finishAndWait()
        XCTAssertEqual(text, "Complete.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.socket.completeSend(URLError(.networkConnectionLost))
        XCTAssertTrue(fixture.events.errors.isEmpty, "Late transport cleanup cannot fail the closed run")
    }

    func testFinishedDuringCaptureCompletesTheSessionAfterDeliveringItsFinal() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit(#"{"tokens":[{"text":"Saved.","is_final":true}],"finished":true}"#)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.events.texts, ["Saved.", "Saved."])
        XCTAssertEqual(fixture.events.finals, [false, true])
        XCTAssertEqual(fixture.socket.cancels, 1)
        let text = await fixture.client.finishAndWait()
        XCTAssertEqual(text, "Saved.", "The completed session's transcript is retained")
    }

    func testFinishedWhileAudioStillDrainingCompletesTheFinish() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.waitForScheduled(SonioxLiveClient.finishDeadline)
        fixture.socket.emit(#"{"tokens":[{"text":"Early.","is_final":true}],"finished":true}"#)
        let text = await finish.value
        XCTAssertEqual(text, "Early.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testAutomaticAndBlankLanguageSelectionsOmitTheHint() throws {
        for selection in [nil, "", "Automatic", "  Automatic  "] {
            let value = SonioxLiveClient.configPayload(
                apiKey: "synthetic", model: "stt-rt-v5", language: selection, sampleRate: 16_000
            )
            XCTAssertNil(value["language_hints"])
        }
        let value = SonioxLiveClient.configPayload(
            apiKey: "synthetic", model: "stt-rt-v5", language: "en_GB", sampleRate: 16_000
        )
        XCTAssertEqual(value["language_hints"] as? [String], ["en"])
    }
}
