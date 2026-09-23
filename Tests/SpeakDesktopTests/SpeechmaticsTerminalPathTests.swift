import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
import SpeakDesktop

/// `EndOfTranscript` is authoritative only once the client's ordered
/// `EndOfStream` has been handed to the socket. Earlier it is a failure the host
/// must see; later, nothing that arrives can disturb the completed session.
final class SpeechmaticsTerminalPathTests: XCTestCase {
    func testUnexpectedEndOfTranscriptWhileActiveFailsTheDesktopSession() {
        let fixture = SpeechmaticsLiveFixture()
        let session = DesktopLiveSession(client: fixture.client)
        session.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Partial.")
        session.sendAudio(Data(repeating: 1, count: 3_200))
        XCTAssertEqual(socket.binary.count, 1, "Microphone data is still in flight")
        socket.endOfTranscript()
        let snapshot = session.snapshot()
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.error, SpeechmaticsRealtimeError.unexpectedEndOfTranscript.errorDescription)
        XCTAssertEqual(snapshot.text, "Partial.")
        XCTAssertEqual(socket.cancels, 1)
        session.sendAudio(Data(repeating: 2, count: 3_200))
        XCTAssertEqual(socket.binary.count, 1, "The host no longer records into a closed client")
        socket.completeSend()
        XCTAssertEqual(session.snapshot(), snapshot, "A stale completion changes nothing")
    }

    func testEndOfTranscriptWhileAdmittedAudioIsStillWaitingIsAFailure() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Kept.")
        fixture.client.sendAudio(Data(repeating: 1, count: 3_200))
        fixture.client.sendAudio(Data(repeating: 2, count: 3_200))
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { fixture.client.isFinishing }
        XCTAssertFalse(socket.messageNames.contains("EndOfStream"), "Audio is still draining")
        socket.endOfTranscript()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
        XCTAssertEqual(fixture.events.errors.first as? SpeechmaticsRealtimeError, .unexpectedEndOfTranscript)
        XCTAssertEqual(socket.binary.count, 1, "The queued frame was never sent")
        XCTAssertEqual(socket.cancels, 1)
    }

    func testEndOfTranscriptBeforeTheEndOfStreamCompletionIsAValidFinalisation() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Done.")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.endOfTranscript()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Done.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
        socket.completeSend(URLError(.networkConnectionLost))
        XCTAssertTrue(fixture.events.errors.isEmpty, "The late completion of an acknowledged EndOfStream is stale")
    }

    func testLateCallbacksAfterASuccessfulEndOfTranscriptChangeNothing() async {
        let fixture = SpeechmaticsLiveFixture()
        fixture.start()
        fixture.becomeReady()
        let socket = fixture.socket
        socket.addFinal("Done.")
        let finish = Task { await fixture.client.finishAndWait() }
        await fixture.settle { socket.messageNames.last == "EndOfStream" }
        socket.completeSend()
        socket.endOfTranscript()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Done.")
        fixture.clock.drain().forEach { $0() }
        socket.fail()
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.events.texts, ["Done."])
        let again = await fixture.client.finishAndWait()
        XCTAssertEqual(again, "Done.")
        XCTAssertEqual(socket.cancels, 1)
    }
}
