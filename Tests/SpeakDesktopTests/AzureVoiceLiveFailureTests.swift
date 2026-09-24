import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Error classification: only an empty-buffer answer to this client's own
/// final commit is benign. Every other server error, whichever client event it
/// names, is published as a failure after any withheld text and before the
/// finish returns, so no host can take it for a completed transcript.
final class AzureVoiceLiveFailureTests: XCTestCase {
    func testABarrierCorrelatedServerErrorIsAFailureAndNeverACompletion() async {
        let codes = [
            "server_error", "rate_limit_exceeded", "invalid_request_error", AzureVoiceLiveProtocol.commitEmptyCode
        ]
        for code in codes {
            let fixture = AzureVoiceLiveFixture()
            fixture.start()
            fixture.becomeReady()
            let socket = fixture.socket
            socket.committed("item_a")
            socket.completed("Confirmed.", item: "item_a")
            fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
            let finish = await fixture.finishThroughBarrier(committing: "item_b")
            socket.completed("Withheld.", item: "item_b")
            XCTAssertEqual(socket.cancels, 0, "Only the barrier's answer is outstanding")
            let barrier = fixture.client.currentEventIDs.barrier
            socket.azureError(code: code, type: code == "server_error" ? "server_error" : "invalid_request_error",
                              eventID: barrier)
            let transcript = await finish.value
            XCTAssertEqual(fixture.log.entries, [
                .transcript("Confirmed.", final: true), .transcript("Confirmed. Withheld.", final: true),
                .error("\(AzureVoiceLiveError.serverError(code: code))"), .finished("Confirmed. Withheld.")
            ], "\(code): withheld text, then the error, then the confirmed return")
            XCTAssertEqual(transcript, "Confirmed. Withheld.")
            XCTAssertEqual(fixture.events.errors.count, 1, code)
            XCTAssertEqual(socket.cancels, 1, code)
            socket.acknowledge(sessionType: nil)
            XCTAssertEqual(fixture.events.errors.count, 1, "\(code): a late answer changes nothing")
        }
    }

    func testEveryOtherCommitOrConfigurationCorrelatedErrorIsAFailure() async {
        let cases: [(code: String, correlate: KeyPath<AzureVoiceLiveEventIDs, String>)] = [
            ("server_error", \.commit), ("rate_limit_exceeded", \.commit),
            (AzureVoiceLiveProtocol.commitEmptyCode, \.session)
        ]
        for failure in cases {
            let fixture = AzureVoiceLiveFixture()
            fixture.start()
            fixture.becomeReady()
            let socket = fixture.socket
            fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
            let finish = fixture.finish()
            await fixture.waitForFinishers()
            fixture.completeSends(until: "input_audio_buffer.commit")
            let ids = fixture.client.currentEventIDs
            socket.azureError(code: failure.code, eventID: ids[keyPath: failure.correlate])
            let transcript = await finish.value
            XCTAssertNil(transcript)
            let expected: AzureVoiceLiveError = failure.correlate == \AzureVoiceLiveEventIDs.session
                ? .sessionRejected(code: failure.code) : .serverError(code: failure.code)
            XCTAssertEqual(fixture.events.errors.first as? AzureVoiceLiveError, expected, failure.code)
            XCTAssertEqual(fixture.events.errors.count, 1)
            XCTAssertEqual(socket.cancels, 1)
        }
    }

    func testAConfigurationRejectionFailsTheSessionBeforeAnyAudioLeaves() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        fixture.socket.open()
        fixture.socket.completeSend()
        fixture.socket.azureError(code: "invalid_value", eventID: fixture.client.currentEventIDs.session)
        XCTAssertEqual(fixture.events.errors.first as? AzureVoiceLiveError, .sessionRejected(code: "invalid_value"))
        XCTAssertTrue(fixture.socket.audio.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testAnUncorrelatedErrorDuringTheSessionIsAFailureWithItsCode() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.committed("item_a")
        fixture.socket.completed("Before.", item: "item_a")
        fixture.socket.azureError(code: "rate_limit_exceeded")
        XCTAssertEqual(fixture.events.errors.first as? AzureVoiceLiveError, .serverError(code: "rate_limit_exceeded"))
        XCTAssertEqual(fixture.events.texts, ["Before."])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testADroppedConnectionWhileFinishingDeliversTheWithheldDraftBeforeTheError() async {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.committed("item_a")
        socket.completed("Kept.", item: "item_a")
        fixture.client.sendAudio(AzureVoiceLiveFixture.frame(0))
        let finish = await fixture.finishThroughBarrier(committing: "item_b")
        socket.delta("Nearly the last", item: "item_b")
        socket.fail()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.", "A failed finish returns confirmed text only")
        let entries = fixture.log.entries
        XCTAssertEqual(Array(entries.prefix(2)), [
            .transcript("Kept.", final: true), .transcript("Kept. Nearly the last", final: false)
        ], "The host keeps the draft Azure sent while the finish waited")
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.last, .finished("Kept."))
        XCTAssertEqual(fixture.events.errors.count, 1, "The drop is published before the finish returns")
    }

    func testAFrameThatIsNotTypedJSONIsAProtocolFailure() {
        let fixture = AzureVoiceLiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.socket.emit("not json")
        XCTAssertEqual(fixture.events.errors.map(\.localizedDescription),
                       [AzureSpeechError.invalidResponse.localizedDescription])
        XCTAssertEqual(fixture.socket.cancels, 1)
    }
}
