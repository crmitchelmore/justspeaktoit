import Foundation
import XCTest
@testable import SpeakApp

final class SonioxControllerClientTests: XCTestCase {
    func testCumulativeFinalsAndRevisionsReplaceWithoutDuplicatingWords() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        var displays: [String] = []
        adapter.start(onTranscript: { displays.append($0); _ = $1 }, onError: { _ in })
        client.transcript?("hello", true)
        client.transcript?("Hello, world.", true)
        client.transcript?("Hello, world. A draft", false)
        XCTAssertEqual(displays, ["hello", "Hello, world.", "Hello, world. A draft"])
        XCTAssertEqual(adapter.snapshot.confirmedText, "Hello, world.")
        client.result = "Hello, world. A final sentence."
        let snapshot = await adapter.finishAndWait()
        XCTAssertEqual(snapshot.text, client.result)
        XCTAssertEqual(snapshot.confirmedText, client.result)
    }

    func testNilFinalRetainsDraftAndConfirmedText() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.transcript?("Confirmed.", true)
        client.transcript?("Confirmed. Still a draft", false)
        let snapshot = await adapter.finishAndWait()
        XCTAssertEqual(snapshot.text, "Confirmed. Still a draft")
        XCTAssertEqual(snapshot.confirmedText, "Confirmed.")
    }

    func testSilenceAndWhitespaceFinalStayEmpty() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in })
        client.result = " \n "
        let snapshot = await adapter.finishAndWait()
        XCTAssertEqual(snapshot.text, "")
        XCTAssertEqual(snapshot.confirmedText, "")
        XCTAssertNil(snapshot.error)
    }

    func testErrorIsStoredBeforeFinishReturnsEvenIfMainActorDeliveryIsDeferred() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        var deferred: Error?
        adapter.start(onTranscript: { _, _ in }, onError: { deferred = $0 })
        client.transcript?("Best available draft", false)
        client.onFinish = { client.error?(URLError(.networkConnectionLost)) }
        let snapshot = await adapter.finishAndWait()
        XCTAssertNotNil(deferred)
        XCTAssertEqual((snapshot.error as? URLError)?.code, .networkConnectionLost)
        XCTAssertEqual(snapshot.text, "Best available draft")
    }

    func testErrorCallbackCanCancelReentrantlyWithoutLosingFinishResult() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        adapter.start(onTranscript: { _, _ in }, onError: { _ in adapter.cancel() })
        client.result = "Confirmed before failure."
        client.onFinish = { client.error?(URLError(.timedOut)) }
        let snapshot = await adapter.finishAndWait()
        XCTAssertEqual(snapshot.text, "Confirmed before failure.")
        XCTAssertEqual(snapshot.confirmedText, snapshot.text)
        XCTAssertEqual((snapshot.error as? URLError)?.code, .timedOut)
        XCTAssertEqual(client.cancels, 1)
    }

    func testCallbacksRunOutsideLockAndLateCallbacksCannotMutateFinishedSnapshot() async {
        let client = SonioxControllerFakeClient()
        let adapter = SonioxControllerClient(client: client)
        var observed: [String] = []
        adapter.start(onTranscript: { _, _ in observed.append(adapter.snapshot.text) }, onError: { _ in })
        client.transcript?("Interim", false)
        client.result = "Final."
        _ = await adapter.finishAndWait()
        client.transcript?("stale", true)
        client.error?(URLError(.timedOut))
        XCTAssertEqual(observed, ["Interim"])
        XCTAssertEqual(adapter.snapshot.text, "Final.")
        XCTAssertNil(adapter.snapshot.error)
    }

    func testCancelledAdapterRejectsAudioRestartAndCallbacksWithoutAffectingReplacement() {
        let old = SonioxControllerFakeClient()
        let oldAdapter = SonioxControllerClient(client: old)
        oldAdapter.start(onTranscript: { _, _ in }, onError: { _ in })
        old.transcript?("Old text", false)
        oldAdapter.cancel()
        let next = SonioxControllerFakeClient()
        let nextAdapter = SonioxControllerClient(client: next)
        nextAdapter.start(onTranscript: { _, _ in }, onError: { _ in })
        next.transcript?("New text", false)
        oldAdapter.start(onTranscript: { _, _ in XCTFail("restarted") }, onError: { _ in })
        oldAdapter.sendAudio(Data([1, 2]))
        old.transcript?("Stale text", true)
        old.error?(URLError(.timedOut))
        XCTAssertEqual(old.starts, 1)
        XCTAssertTrue(old.audio.isEmpty)
        XCTAssertEqual(oldAdapter.snapshot.text, "Old text")
        XCTAssertNil(oldAdapter.snapshot.error)
        XCTAssertEqual(nextAdapter.snapshot.text, "New text")
        XCTAssertFalse(LiveTranscriptionRun.isCurrent(oldAdapter, activeStream: nextAdapter))
    }
}
