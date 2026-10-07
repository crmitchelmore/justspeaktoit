import Foundation
import XCTest
@testable import SpeakCore

final class ElevenLabsProtocolReviewTests: XCTestCase {
    func testActiveManualCommitAdvertisesFlush() {
        XCTAssertTrue(ElevenLabsLiveClient(apiKey: "synthetic").finishFlushesBufferedAudio)
    }
    func testAutomaticLanguageValuesNeverReachTheWire() throws {
        for language in [nil, "", " auto ", "AUTOMATIC"] {
            let url = try XCTUnwrap(ElevenLabsLiveProtocol.webSocketURL(
                modelID: "scribe_v2_realtime", language: language, sampleRate: 16_000
            ))
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertFalse(query.contains { $0.name == "language_code" })
        }
    }
    func testDocumentedGenericErrorIsTerminal() {
        guard case .serverError? = ElevenLabsRealtimeEvent.parse(#"{"message_type":"error","error":"failed"}"#) else {
            return XCTFail("Documented generic provider error was ignored")
        }
    }
    func testDelayedTimestampMetadataDoesNotDuplicateSegment() async {
        let client = ElevenLabsLiveClient(apiKey: "synthetic")
        client.parseTranscriptResponse(#"{"message_type":"committed_transcript","text":"Hello."}"#)
        client.parseTranscriptResponse(
            #"{"message_type":"committed_transcript_with_timestamps","text":"Hello.","words":[]}"#
        )
        let text = await client.finishAndWait()
        XCTAssertEqual(text, "Hello.")
    }
    func testDisconnectedFinishReportsErrorBeforeReturn() async {
        let factory = AssemblyAISocketFactory()
        let events = AssemblyAITestEvents()
        let client = ElevenLabsLiveClient(apiKey: "synthetic", makeConnection: { factory.make($0) })
        client.start(onTranscript: { events.transcript($0, final: $1) }, onError: { events.fail($0) })
        let socket = factory.sockets[0]
        socket.open()
        socket.emit(#"{"message_type":"session_started"}"#)
        client.sendAudio(Data(repeating: 0, count: 3200))
        socket.completeSend()
        let committed = expectation(description: "Manual commit sent")
        socket.onSend = { message in
            if case .text(let text) = message, text.contains("\"commit\":true") { committed.fulfill() }
        }
        let finish = Task { await client.finishAndWait() }
        await fulfillment(of: [committed], timeout: 2)
        socket.completeSend()
        socket.fail()
        _ = await finish.value
        XCTAssertEqual(events.errors.count, 1, "Network failure is not completed transcription")
    }
}
