import Foundation
import XCTest
@testable import SpeakCore

extension SonioxPortableLifecycleTests {
    // MARK: - Awaiting the final after stop

    func testFinishDrainsAudioSendsEndOfStreamThenReturnsTheWholeTranscriptOnce() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.tokens([(text: "Hello ", final: true), (text: "world", final: false)]))
        fixture.client.sendAudio(Data(repeating: 7, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.binary.count == 1 }
        XCTAssertEqual(socket.binary.count, 1, "The queued audio drains before end-of-stream")
        socket.completeSend()
        await fixture.settle { socket.binary.count == 2 }
        XCTAssertEqual(socket.binary.last, Data(), "The end-of-stream frame is empty")
        socket.completeSend()
        // Finalised tail arrives during the silent finish, then the finished frame.
        socket.emit(Self.tokens([(text: "world.", final: true)]))
        socket.emit(Self.finished())
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Hello world.")
        XCTAssertEqual(fixture.events.texts, ["Hello world"], "The trailing final is returned once, not redelivered")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testGracefulStopDeliversTheFinalWhileFinishing() {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.tokens([(text: "Final ", final: true), (text: "words", final: false)]))
        fixture.client.stop()
        XCTAssertEqual(socket.binary.last, Data(), "Stop flushes with the end-of-stream frame")
        socket.completeSend()
        socket.emit(Self.tokens([(text: "words.", final: true)]))
        socket.emit(Self.finished())
        XCTAssertEqual(fixture.events.texts, ["Final words", "Final words."])
        XCTAssertEqual(fixture.events.finals, [false, true], "Stop delivers the whole transcript as a final")
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testServerClosingBeforeFinishedReportsFailure() async {
        let fixture = SonioxLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.emit(Self.tokens([(text: "Only final.", final: true)]))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.binary.last == Data() }
        socket.completeSend()
        // Transport delivery is not the provider's finished acknowledgement.
        socket.fail()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Only final.")
        XCTAssertEqual(fixture.events.errors.count, 1, "A close before finished is incomplete")
        XCTAssertEqual(socket.cancels, 1)
    }

    // MARK: - Offline seam

    func testOfflineFullTranscriptAndPrerollContractsRemainCompatible() async {
        let fixture = SonioxLiveFixture()
        // Captured before start(): held in the pre-roll buffer.
        fixture.client.sendAudio(Data([1, 2]))
        XCTAssertEqual(fixture.client.preroll.drain(), [Data([1, 2])])
        // The offline parse seam folds finals into the idle run; finishAndWait
        // returns them even with no socket, exactly as a stop after a dropped
        // connection would.
        fixture.client.ingest(Self.tokens([(text: "Hello ", final: true)]))
        fixture.client.ingest(Self.tokens([(text: "world.", final: true)]))
        let transcript = await fixture.client.finishAndWait()
        XCTAssertEqual(transcript, "Hello world.")
        fixture.client.stop()
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertTrue(fixture.client.preroll.isEmpty)
    }
}
