import Foundation
import XCTest
@testable import SpeakCore

final class AssemblyAIPortableLifecycleTests: XCTestCase {
    func testCanonicalRequestAndBothHandshakeGates() throws {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        let request = fixture.factory.requests[0]
        XCTAssertEqual(request.url?.host, AssemblyAIStreamingEndpoint.europe.rawValue)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "synthetic")
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["speech_model"], AssemblyAIModels.universal35ProAPIName)
        XCTAssertNil(query["format_turns"])
        let socket = fixture.factory.sockets[0]
        fixture.client.sendAudio(Data(repeating: 1, count: 3200))
        socket.begin()
        XCTAssertTrue(socket.binary.isEmpty)
        socket.open()
        XCTAssertEqual(socket.binary.map(\.count), [3200])
        fixture.client.cancel()
    }

    func testOnlyOneAudioSendIsInFlightAndTailIsPaddedBeforeForceEndpoint() async {
        let fixture = begun()
        let socket = fixture.factory.sockets[0]
        fixture.client.sendAudio(Data(repeating: 17, count: 3210))
        let finish = Task { await fixture.client.finishAndWait() }
        await settle { fixture.clock.pending(AssemblyAILiveClient.finishDeadline) == 2 }
        XCTAssertEqual(socket.binary.map(\.count), [3200])
        XCTAssertTrue(socket.controls.isEmpty)
        socket.completeSend()
        XCTAssertEqual(socket.binary.map(\.count), [3200, 1600])
        XCTAssertEqual(socket.binary[1].prefix(10), Data(repeating: 17, count: 10))
        XCTAssertTrue(socket.binary[1].dropFirst(10).allSatisfy { $0 == 0 })
        XCTAssertTrue(socket.controls.isEmpty)
        socket.completeSend()
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#])
        fixture.client.cancel()
        _ = await finish.value
    }

    func testFinishDrainsThenWaitsForFormattedTurnBeforeTerminate() async {
        let fixture = begun()
        let socket = fixture.factory.sockets[0]
        socket.emit(Self.turn("First.", order: 0))
        fixture.client.sendAudio(Data(repeating: 0, count: 3200))
        let forced = expectation(description: "ForceEndpoint after completed audio")
        socket.onSend = { if case .text(let text) = $0, text.contains("ForceEndpoint") { forced.fulfill() } }
        let finish = Task { await fixture.client.finishAndWait() }
        socket.completeSend()
        await fulfillment(of: [forced], timeout: 2)
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#])
        socket.completeSend()
        socket.emit(Self.turn("second", order: 1, formatted: false))
        XCTAssertEqual(socket.controls.count, 1)
        socket.emit(Self.turn("Second.", order: 1))
        XCTAssertEqual(socket.controls, [#"{"type":"ForceEndpoint"}"#, #"{"type":"Terminate"}"#])
        socket.completeSend()
        socket.emit(#"{"type":"Termination"}"#)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "First. Second.")
        XCTAssertEqual(fixture.events.texts, ["First."])
        XCTAssertEqual(socket.cancels, 1)
    }

    func testStopIsImmediateAndKeepsTheTextReceivedSoFar() async {
        let fixture = begun()
        let socket = fixture.factory.sockets[0]
        socket.emit(Self.turn("Final words.", order: 0))
        fixture.client.sendAudio(Data(repeating: 0, count: 3200))
        fixture.client.stop()
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(socket.controls.isEmpty, "No ForceEndpoint or Terminate follows an immediate stop")
        socket.completeSend()
        socket.emit(Self.turn("Late.", order: 1))
        XCTAssertEqual(fixture.events.texts, ["Final words."])
        XCTAssertEqual(fixture.events.finals, [false])
        let text = await fixture.client.finishAndWait()
        XCTAssertEqual(text, "Final words.")
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testEndpointAndTerminationWaitsHaveBoundedFallbacks() async {
        let fixture = begun()
        let socket = fixture.factory.sockets[0]
        fixture.client.sendAudio(Data(repeating: 0, count: 3200))
        socket.completeSend()
        let finish = Task { await fixture.client.finishAndWait() }
        await settle { socket.controls == [#"{"type":"ForceEndpoint"}"#] }
        socket.completeSend()
        fixture.clock.fire(ModelCatalog.liveCapabilities(for: AssemblyAIModels.universal35ProStreamingID)
            .postStopFinalizeBudget)
        XCTAssertEqual(socket.controls.last, #"{"type":"Terminate"}"#)
        socket.completeSend()
        fixture.clock.fire(3)
        XCTAssertEqual(socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        _ = await finish.value
    }

    func testEUFailureRetriesGlobalOnceAndRetainsPreBeginPCM() {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        fixture.client.sendAudio(Data(repeating: 42, count: 3200))
        let first = fixture.factory.sockets[0]
        first.fail()
        XCTAssertEqual(fixture.factory.requests.map { $0.url?.host },
                       [AssemblyAIStreamingEndpoint.europe.rawValue, AssemblyAIStreamingEndpoint.global.rawValue])
        let second = fixture.factory.sockets[1]
        second.open(); second.begin()
        XCTAssertEqual(second.binary, [Data(repeating: 42, count: 3200)])
        XCTAssertEqual(first.cancels, 1)
        second.fail()
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        XCTAssertEqual(fixture.events.errors.count, 1)
    }

    func testBeginTimeoutRetriesOnlyBeforeStoppingAndOnlyOnce() {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        fixture.clock.fire(8)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        fixture.clock.fire(8)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        XCTAssertEqual(fixture.events.errors.count, 1)
        let stopping = AssemblyAILiveFixture()
        stopping.start()
        stopping.client.stop()
        stopping.factory.sockets[0].fail()
        XCTAssertEqual(stopping.factory.sockets.count, 1)
    }

    func testNoFallbackAfterBeginAndNoCallbacksAfterReplacement() {
        let fixture = begun()
        let old = fixture.factory.sockets[0]
        fixture.client.sendAudio(Data(repeating: 0, count: 3200))
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        old.open(); old.begin(); old.completeSend(URLError(.networkConnectionLost))
        oldDeadlines.forEach { $0() }
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        let current = fixture.factory.sockets[1]
        current.open(); current.begin(); current.fail()
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        XCTAssertEqual(fixture.events.errors.count, 1)
    }

    func testQueuedPartialAndInFlightAudioShareOneFiveSecondBudget() {
        let fixture = begun()
        fixture.client.sendAudio(Data(repeating: 0, count: 160_000))
        fixture.client.sendAudio(Data([0, 0]))
        XCTAssertEqual(fixture.factory.sockets[0].binary.count, 1)
        XCTAssertEqual(fixture.events.errors.count, 1)
        XCTAssertEqual(fixture.factory.sockets[0].cancels, 1)
    }

    func testMissingKeyAndSendStallFailVisiblyWhileASplitSampleCarriesOver() {
        let missing = AssemblyAILiveFixture(key: " \n")
        missing.start()
        XCTAssertTrue(missing.factory.sockets.isEmpty)
        XCTAssertEqual(missing.events.errors.count, 1)
        let odd = begun()
        odd.client.sendAudio(Data([1]))
        odd.client.sendAudio(Data(repeating: 2, count: 3199))
        XCTAssertTrue(odd.events.errors.isEmpty, "A chunk need not hold whole samples")
        XCTAssertEqual(odd.factory.sockets[0].binary, [Data([1]) + Data(repeating: 2, count: 3199)])
        odd.client.cancel()
        let stalled = begun()
        stalled.client.sendAudio(Data(repeating: 0, count: 3200))
        stalled.clock.fire(5)
        XCTAssertEqual(stalled.events.errors.count, 1)
    }

    func testCancelAbortsWithoutControlFramesOrReconnect() async {
        let fixture = begun()
        let socket = fixture.factory.sockets[0]
        socket.emit(Self.turn("Retained.", order: 0))
        fixture.client.cancel()
        socket.fail()
        fixture.clock.fire(8)
        XCTAssertTrue(socket.controls.isEmpty)
        XCTAssertEqual(fixture.factory.sockets.count, 1)
        let text = await fixture.client.finishAndWait()
        XCTAssertEqual(text, "Retained.")
    }

    func testSameTurnCorrectionsReplaceAndUnformattedFinalDoesNotCommit() async {
        let fixture = begun()
        let socket = fixture.factory.sockets[0]
        socket.emit(Self.turn("first", order: 0, formatted: false))
        socket.emit(Self.turn("First.", order: 0))
        socket.emit(Self.turn("Corrected.", order: 0))
        socket.emit(Self.turn("Next.", order: 1))
        fixture.client.cancel()
        let text = await fixture.client.finishAndWait()
        XCTAssertEqual(text, "Corrected. Next.")
        XCTAssertEqual(fixture.events.texts, ["first", "First.", "Corrected.", "Corrected. Next."])
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Condition did not settle")
    }

    private func begun() -> AssemblyAILiveFixture {
        let fixture = AssemblyAILiveFixture()
        fixture.start()
        fixture.factory.sockets[0].open()
        fixture.factory.sockets[0].begin()
        return fixture
    }

    private static func turn(_ text: String, order: Int, formatted: Bool = true) -> String {
        "{\"type\":\"Turn\",\"turn_order\":\(order),\"turn_is_formatted\":\(formatted)," +
            "\"end_of_turn\":true,\"transcript\":\"\(text)\"}"
    }
}
