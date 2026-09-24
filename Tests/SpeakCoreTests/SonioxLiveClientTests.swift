import Foundation
import XCTest
@testable import SpeakCore

final class SonioxLiveClientTests: XCTestCase {
    func testOrdersConfigurationPCMFinalizeAndEOSAndWaitsForFinished() async throws {
        let socket = TestLiveWebSocket()
        let factory = TestSocketFactory([socket])
        let client = SonioxLiveClient(
            apiKey: "test-key", language: "en", timing: .init(overall: 0.4),
            socketFactory: factory.make
        )
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        client.sendAudio(Data([1, 2, 3]))
        let condition1 = await eventually { socket.messages.count == 2 }
        XCTAssertTrue(condition1)
        async let result = client.finishAndWait()
        let condition2 = await eventually { socket.messages.count == 4 }
        XCTAssertTrue(condition2)
        try? await Task.sleep(nanoseconds: 30_000_000)
        socket.emit(#"{"tokens":[{"text":"Hello","is_final":true},{"text":"<fin>","is_final":true}]}"#)
        socket.emit(#"{"tokens":[{"text":" world","is_final":true}]}"#)
        try? await Task.sleep(nanoseconds: 20_000_000)
        socket.emit(#"{"tokens":[],"finished":true}"#)
        let awaited3 = await result
        XCTAssertEqual(awaited3, "Hello world")
        let awaited4 = await client.finishAndWait()
        XCTAssertEqual(awaited4, "Hello world")

        guard case .string(let config) = socket.messages[0] else { return XCTFail("configuration must be text") }
        XCTAssertEqual(try json(config)["api_key"] as? String, "test-key")
        guard case .data(let pcm) = socket.messages[1] else { return XCTFail("PCM must be binary") }
        XCTAssertEqual(pcm, Data([1, 2, 3]))
        guard case .string(let finalize) = socket.messages[2] else { return XCTFail("finalize must be text") }
        XCTAssertEqual(try json(finalize)["type"] as? String, "finalize")
        guard case .data(let eos) = socket.messages[3] else { return XCTFail("EOS must be binary") }
        XCTAssertTrue(eos.isEmpty)
    }

    func testFinishDoesNotResolveWhenSendsCompleteOrFinMarkerArrives() async {
        let socket = TestLiveWebSocket()
        let client = makeClient(socket, overall: 0.3)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let condition5 = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(condition5)
        async let result = client.finishAndWait()
        let condition6 = await eventually { socket.messages.count == 3 }
        XCTAssertTrue(condition6)
        socket.emit(#"{"tokens":[{"text":"Tail","is_final":true},{"text":"<fin>","is_final":true}]}"#)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(socket.cancelCount, 0)
        socket.emit(#"{"tokens":[],"finished":true}"#)
        let awaited7 = await result
        XCTAssertEqual(awaited7, "Tail")
    }

    func testRepeatedTokensAreSpeechButDuplicateMarkersDoNotDoubleFinalCallback() async {
        let socket = TestLiveWebSocket()
        let client = makeClient(socket)
        let final = expectation(description: "one final callback")
        final.expectedFulfillmentCount = 1
        client.start(onTranscript: { _, isFinal in if isFinal { final.fulfill() } }, onError: { _ in })
        let condition8 = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(condition8)
        let repeatedTokens = #"{"tokens":[{"text":"Yes ","is_final":true},"#
            + #"{"text":"Yes","is_final":true},{"text":"<fin>","is_final":true}]}"#
        socket.emit(repeatedTokens)
        socket.emit(#"{"tokens":[{"text":"<fin>","is_final":true}]}"#)
        await fulfillment(of: [final], timeout: 1)
        client.stop()
        let awaited9 = await client.finishAndWait()
        XCTAssertEqual(awaited9, "Yes Yes")
    }

    func testTimeoutAndConcurrentWaitersReturnCommittedSnapshot() async {
        let socket = TestLiveWebSocket()
        let client = makeClient(socket, overall: 0.08)
        client.start(onTranscript: { _, _ in }, onError: { _ in })
        let condition10 = await eventually { socket.messages.count == 1 }
        XCTAssertTrue(condition10)
        socket.emit(#"{"tokens":[{"text":"kept","is_final":true}]}"#)
        async let one = client.finishAndWait()
        async let two = client.finishAndWait()
        let awaited11 = await one
        XCTAssertEqual(awaited11, "kept")
        let awaited12 = await two
        XCTAssertEqual(awaited12, "kept")
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testRestartIgnoresOldReceiveAndSendCompletions() async {
        let old = TestLiveWebSocket()
        old.automaticallyCompletesSends = false
        let fresh = TestLiveWebSocket()
        let factory = TestSocketFactory([old, fresh])
        let client = SonioxLiveClient(
            apiKey: "test-key", timing: .init(overall: 0.1), socketFactory: factory.make
        )
        var callbacks: [String] = []
        let lock = NSLock()
        client.start(onTranscript: { text, _ in lock.withLock { callbacks.append("old:\(text)") } }, onError: { _ in })
        let condition13 = await eventually { old.messages.count == 1 }
        XCTAssertTrue(condition13)
        client.start(onTranscript: { text, _ in lock.withLock { callbacks.append("new:\(text)") } }, onError: { _ in })
        let condition14 = await eventually { fresh.messages.count == 1 }
        XCTAssertTrue(condition14)
        old.completeNextSend()
        old.emit(#"{"tokens":[{"text":"stale","is_final":true}],"finished":true}"#)
        fresh.emit(#"{"tokens":[{"text":"fresh","is_final":true}],"finished":true}"#)
        let receivedFresh = await eventually {
            lock.withLock { callbacks.contains(where: { $0.contains("fresh") }) }
        }
        XCTAssertTrue(receivedFresh)
        XCTAssertFalse(lock.withLock { callbacks.contains(where: { $0.contains("stale") }) })
        let awaited15 = await client.finishAndWait()
        XCTAssertEqual(awaited15, "fresh")
    }

    func testStopStillCancelsWhenCallerDropsLastClientReference() async {
        let socket = TestLiveWebSocket()
        weak var released: SonioxLiveClient?
        do {
            var client: SonioxLiveClient? = makeClient(socket)
            released = client
            client?.start(onTranscript: { _, _ in }, onError: { _ in })
            let condition16 = await eventually { socket.state == .running }
            XCTAssertTrue(condition16)
            client?.stop()
            client = nil
        }
        let condition17 = await eventually { socket.cancelCount > 0 }
        XCTAssertTrue(condition17)
        let condition18 = await eventually { released == nil }
        XCTAssertTrue(condition18)
    }

    private func makeClient(_ socket: TestLiveWebSocket, overall: TimeInterval = 0.4) -> SonioxLiveClient {
        SonioxLiveClient(
            apiKey: "test-key", timing: .init(overall: overall),
            socketFactory: TestSocketFactory([socket]).make
        )
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
