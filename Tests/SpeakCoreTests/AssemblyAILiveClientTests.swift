import Foundation
@testable import SpeakCore
import XCTest

final class AssemblyAILiveClientTests: XCTestCase {
    func testAudioWaitsForBeginThenSendsMinimumFramesInOrder() async throws {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        client.sendAudio(Data(repeating: 1, count: 1_600))
        client.sendAudio(Data(repeating: 2, count: 1_600))
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        XCTAssertTrue(socket.messages.isEmpty)

        socket.emit(#"{"type":"Begin"}"#)
        let didSendFrame = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(didSendFrame)
        guard case .data(let frame) = try XCTUnwrap(socket.messages.first) else {
            return XCTFail("Expected framed PCM")
        }
        XCTAssertEqual(frame.count, 3_200)
        XCTAssertEqual(frame.first, 1)
        XCTAssertEqual(frame.last, 2)
    }

    func testFinishOrdersResidualForceFinalGraceAndTerminate() async throws {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        var events: [String] = []
        let lock = NSLock()
        client.onUtteranceBoundary = { text in lock.withLock { events.append("boundary:\(text)") } }
        client.start(
            onTranscript: { text, _ in lock.withLock { events.append("transcript:\(text)") } },
            onError: { _ in }
        )
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        socket.emit(#"{"type":"Begin"}"#)
        socket.emit(
            #"""
            {"type":"Turn","turn_order":0,"turn_is_formatted":true,
             "end_of_turn":true,"transcript":"First.","utterance":"First."}
            """#
        )
        _ = await eventually { lock.withLock { events.count == 2 } }
        client.sendAudio(Data(repeating: 7, count: 800))

        let finish = Task { await client.finishAndWait() }
        let didForce = await eventually {
            textMessages(socket).contains(#"{"type":"ForceEndpoint"}"#)
        }
        XCTAssertTrue(didForce)
        let final = #"""
        {"type":"Turn","turn_order":1,"turn_is_formatted":true,
         "end_of_turn":true,"transcript":"Done.","utterance":"Done."}
        """#
        socket.emit(final)
        let didTerminate = await eventually {
            textMessages(socket).contains(#"{"type":"Terminate"}"#)
        }
        XCTAssertTrue(didTerminate)
        socket.emit(#"{"type":"Termination"}"#)

        let transcript = await finish.value
        XCTAssertEqual(transcript, "First. Done.")
        _ = await eventually { lock.withLock { events.count == 3 } }
        XCTAssertEqual(lock.withLock { events }, [
            "boundary:First.", "transcript:First.", "boundary:Done."
        ])
        let messages = socket.messages
        XCTAssertEqual(messages.count, 3)
        guard case .data(let residual) = messages[0] else { return XCTFail("Expected residual") }
        XCTAssertEqual(residual.count, 1_600)
        XCTAssertEqual(client.transcriptSnapshot(captureDuration: 2).segments.map(\.text), [
            "First.", "Done."
        ])
    }

    func testPendingAudioCompletionBlocksForceEndpoint() async {
        let socket = TestLiveWebSocket()
        socket.automaticallyCompletesSends = false
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        socket.emit(#"{"type":"Begin"}"#)
        client.sendAudio(Data(repeating: 1, count: 3_200))
        let didAdmitAudio = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(didAdmitAudio)

        let finish = Task { await client.finishAndWait() }
        await Task.yield()
        XCTAssertTrue(textMessages(socket).isEmpty)
        socket.completeNextSend()
        let didForce = await eventually {
            textMessages(socket).contains(#"{"type":"ForceEndpoint"}"#)
        }
        XCTAssertTrue(didForce)
        socket.completeNextSend()
        let didTerminate = await eventually {
            textMessages(socket).contains(#"{"type":"Terminate"}"#)
        }
        XCTAssertTrue(didTerminate)
        socket.emit(#"{"type":"Termination"}"#)
        let transcript = await finish.value
        XCTAssertNil(transcript)
    }

    func testFinishBeforeBeginReturnsPromptlyWithoutSendingControls() async {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)

        let transcript = await client.finishAndWait()

        XCTAssertNil(transcript)
        XCTAssertTrue(socket.messages.isEmpty)
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testPreBeginFailureFallsBackWithoutSendingAudioOnFailedSocket() async {
        let europe = TestLiveWebSocket()
        let global = TestLiveWebSocket()
        let factory = TestSocketFactory([europe, global])
        let client = makeClient(factory)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        client.sendAudio(Data(repeating: 3, count: 3_200))
        let didStartEurope = await eventually { europe.state == .running }
        XCTAssertTrue(didStartEurope)
        europe.failReceive()

        let didStartGlobal = await eventually { global.state == .running }
        XCTAssertTrue(didStartGlobal)
        XCTAssertTrue(europe.messages.isEmpty)
        global.emit(#"{"type":"Begin"}"#)
        let didSendFrame = await eventually { global.messages.count == 1 }
        XCTAssertTrue(didSendFrame)
        XCTAssertEqual(factory.requests.map { $0.url?.host }, [
            AssemblyAIStreamingEndpoint.europe.rawValue,
            AssemblyAIStreamingEndpoint.global.rawValue
        ])
    }

    func testPreBeginAudioIsBoundedToFiveSeconds() async {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)

        for index in 0..<50 {
            client.sendAudio(Data(repeating: UInt8(index), count: 3_200))
        }
        client.sendAudio(Data(repeating: 50, count: 3_199))
        socket.emit(#"{"type":"Begin"}"#)
        let sentBoundedAudio = await eventually { socket.messages.count == 49 }
        XCTAssertTrue(sentBoundedAudio)
        guard case .data(let first) = socket.messages[0] else {
            return XCTFail("Expected buffered PCM")
        }
        XCTAssertEqual(first.first, 1)
        client.sendAudio(Data([50]))
        let sentResidual = await eventually { socket.messages.count == 50 }
        XCTAssertTrue(sentResidual)
    }

    func testSnapshotSeparatesConfirmedAndInterimText() async {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = makeClient(factory)
        let lock = NSLock()
        var events: [String] = []
        client.onUtteranceBoundary = { _ in lock.withLock { events.append("boundary") } }
        client.start(
            onTranscript: { _, _ in lock.withLock { events.append("transcript") } },
            onError: { _ in }
        )
        let didStart = await eventually { socket.state == .running }
        XCTAssertTrue(didStart)
        socket.emit(#"{"type":"Begin"}"#)
        socket.emit(
            #"""
            {"type":"Turn","turn_order":0,"turn_is_formatted":true,
             "end_of_turn":true,"transcript":"First.","utterance":"First."}
            """#
        )
        socket.emit(
            #"{"type":"Turn","turn_order":1,"turn_is_formatted":false,"end_of_turn":false,"transcript":"Second"}"#
        )
        let didReceiveInterim = await eventually {
            client.transcriptSnapshot(captureDuration: 4).pendingInterim == "Second"
        }
        XCTAssertTrue(didReceiveInterim)
        let snapshot = client.transcriptSnapshot(captureDuration: 4)
        XCTAssertEqual(snapshot.confirmedText, "First.")
        XCTAssertEqual(snapshot.displayText, "First. Second")
        XCTAssertEqual(snapshot.segments.map(\.text), ["First."])
        XCTAssertNil(snapshot.duration)
        _ = await eventually { lock.withLock { events.count == 3 } }
        XCTAssertEqual(lock.withLock { events }, ["boundary", "transcript", "transcript"])
    }

    private func makeClient(_ factory: TestSocketFactory) -> AssemblyAILiveClient {
        AssemblyAILiveClient(
            postStopFinalizeBudget: 0.05,
            stopGracePeriod: 0,
            socketFactory: factory.make
        )
    }
}
