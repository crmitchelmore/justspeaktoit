import Foundation
import XCTest
@testable import SpeakCore

final class AlibabaLiveTests: XCTestCase {
    func testHandshake_GatesPCMAndPreservesPrerollAndSingleFlightOrder() throws {
        let fixture = try AlibabaLiveFixture()
        let frames = [Data(repeating: 1, count: 3_200), Data(repeating: 2, count: 3_200)]
        fixture.client.sendAudio(frames[0])
        fixture.start()
        defer { fixture.client.cancel() }
        fixture.client.sendAudio(frames[1])
        XCTAssertTrue(fixture.socket.binary.isEmpty)
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.controls.count, 1)
        let control = try fixture.control()
        let payload = try XCTUnwrap(control["payload"] as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "fun-asr-realtime")
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16_000)
        fixture.socket.completeSend()
        XCTAssertTrue(fixture.socket.binary.isEmpty, "The WebSocket opening is not ASR readiness")
        try fixture.emit("task-started")
        XCTAssertEqual(fixture.socket.binary, [frames[0]])
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, frames)
        fixture.socket.completeSend()
        fixture.socket.open()
        XCTAssertEqual(fixture.socket.controls.count, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testSentences_ReplacePartialsAndFinalsRetractEmptyAndPreserveTrueRepeats() throws {
        let fixture = try AlibabaLiveFixture()
        try fixture.ready()
        defer { fixture.client.cancel() }
        try fixture.sentence("guess", id: 0, final: false)
        try fixture.sentence("", id: 0, final: false)
        XCTAssertEqual(fixture.client.transcriptSnapshot(captureDuration: 1).resolvedDisplayText, "")
        try fixture.sentence("Yes.", id: 0, final: true)
        try fixture.sentence("Yes.", id: 0, final: true)
        try fixture.sentence("Yes.", id: 1, final: true)
        try fixture.sentence("Corrected.", id: 0, final: true)
        try fixture.sentence("late partial", id: 0, final: false)
        let snapshot = fixture.client.transcriptSnapshot(captureDuration: 2)
        XCTAssertEqual(snapshot.confirmedText, "Corrected. Yes.")
        XCTAssertEqual(snapshot.segments.count, 2)
        XCTAssertEqual(snapshot.pendingInterim, "")
        XCTAssertEqual(fixture.events.texts.last, "Corrected. Yes.")
    }

    func testFinish_DrainsPCMBeforeControlAndWaitsForTaskFinishedReturningWholeTranscript() async throws {
        let fixture = try AlibabaLiveFixture()
        try fixture.ready()
        let frames = [Data(repeating: 1, count: 3_200), Data(repeating: 2, count: 3_200)]
        frames.forEach(fixture.client.sendAudio)
        try fixture.sentence("First.", id: 0, final: true)
        let finishSent = expectation(description: "finish-task")
        fixture.socket.onSend = { message in
            if case .text(let text) = message, text.contains("finish-task") { finishSent.fulfill() }
        }
        let result = Task { await fixture.client.finishAndWait() }
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, frames)
        XCTAssertEqual(fixture.socket.controls.count, 1)
        fixture.socket.completeSend()
        await fulfillment(of: [finishSent], timeout: 2)
        fixture.socket.completeSend()
        try fixture.sentence("Last.", id: 1, final: true)
        try fixture.emit("task-finished")
        let whole = await result.value
        XCTAssertEqual(whole, "First. Last.")
        XCTAssertEqual(fixture.events.texts, ["First."], "Drain results return once, not as duplicate callbacks")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testFinishTimeout_PublishesFailureBeforeReturningRecoveredText() async throws {
        let fixture = try AlibabaLiveFixture()
        try fixture.ready()
        try fixture.sentence("Recovered.", id: 0, final: true)
        let finishSent = expectation(description: "finish-task")
        fixture.socket.onSend = { message in
            if case .text(let text) = message, text.contains("finish-task") { finishSent.fulfill() }
        }
        let result = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [finishSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.clock.fire(5)
        let recovered = await result.value
        XCTAssertEqual(recovered, "Recovered.")
        XCTAssertEqual(fixture.events.errors.last as? AlibabaSpeechError, .missingCompletion)
    }

    func testFinishBeforeReadiness_DrainsAdmittedPCMOnlyAfterTaskStarted() async throws {
        let waiting = expectation(description: "finish waiter registered")
        let fixture = try AlibabaLiveFixture(onSchedule: { seconds, clock in
            if seconds == 5, clock.pending(5) == 2 { waiting.fulfill() }
        })
        fixture.start()
        fixture.client.sendAudio(Data([1, 2]))
        fixture.socket.open()
        fixture.socket.completeSend()
        let result = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertTrue(fixture.socket.binary.isEmpty)
        try fixture.emit("task-started")
        XCTAssertEqual(fixture.socket.binary, [Data([1, 2])])
        XCTAssertEqual(fixture.socket.controls.count, 1)
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.controls.count, 2)
        fixture.socket.completeSend()
        try fixture.emit("task-finished")
        let text = await result.value
        XCTAssertNil(text)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }

    func testWrongTaskAndMalformedResult_DoNotBecomeTranscriptText() throws {
        let fixture = try AlibabaLiveFixture()
        try fixture.ready()
        try fixture.emit("task-failed", taskID: "wrong-task", errorCode: "InvalidApiKey")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        try fixture.emit("result-generated", sentence: [
            "text": "broken", "sentence_end": true, "begin_time": -1
        ])
        XCTAssertEqual(fixture.events.errors.last as? AlibabaSpeechError, .invalidResponse)
        XCTAssertTrue(fixture.events.texts.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testTaskFinishedWithUnfinishedSentence_FailsAndReturnsOnlyConfirmedRecovery() async throws {
        let fixture = try AlibabaLiveFixture()
        try fixture.ready()
        try fixture.sentence("Locked.", id: 0, final: true)
        try fixture.sentence("uncertain", id: 1, final: false)
        let sent = expectation(description: "finish-task")
        fixture.socket.onSend = { message in
            if case .text(let text) = message, text.contains("finish-task") { sent.fulfill() }
        }
        let result = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [sent], timeout: 2)
        fixture.socket.completeSend()
        try fixture.emit("task-finished")
        let recovered = await result.value
        XCTAssertEqual(recovered, "Locked.")
        XCTAssertEqual(fixture.events.errors.last as? AlibabaSpeechError, .missingCompletion)
    }

    func testReadinessAndBackpressure_AreBoundedVisibleErrors() throws {
        let fixture = try AlibabaLiveFixture()
        fixture.start()
        fixture.clock.fire(10)
        XCTAssertEqual(fixture.events.errors.last as? AlibabaSpeechError, .sessionNotReady)
        XCTAssertEqual(fixture.socket.cancels, 1)

        let overflow = try AlibabaLiveFixture()
        overflow.start()
        overflow.client.sendAudio(Data(repeating: 1, count: 160_000))
        overflow.client.sendAudio(Data([1, 2]))
        XCTAssertEqual(overflow.events.errors.count, 1)
        XCTAssertEqual(overflow.socket.cancels, 1)
        XCTAssertTrue(overflow.socket.binary.isEmpty)
    }

    func testSendStall_TaskFailureAndPrematureClosureDoNotSucceed() throws {
        let fixture = try AlibabaLiveFixture()
        try fixture.ready()
        fixture.client.sendAudio(Data([1, 2]))
        fixture.clock.fire(5)
        XCTAssertEqual(fixture.events.errors.count, 1)

        let rejection = try AlibabaLiveFixture()
        rejection.start()
        rejection.socket.open()
        try rejection.emit("task-failed", errorCode: "InvalidApiKey")
        XCTAssertEqual(rejection.events.errors.last as? AlibabaSpeechError, .providerFailure("InvalidApiKey"))

        let closed = try AlibabaLiveFixture()
        try closed.ready()
        closed.socket.fail()
        XCTAssertEqual(closed.events.errors.count, 1)
        XCTAssertEqual(closed.socket.cancels, 1)
    }

    func testCancelAndReplacement_IsolateLateCallbacksAndDeadlineFromNewRun() throws {
        let fixture = try AlibabaLiveFixture()
        try fixture.ready()
        let oldSocket = fixture.socket
        fixture.client.sendAudio(Data([1, 2]))
        let oldDeadlines = fixture.clock.drain()
        fixture.client.cancel()
        fixture.start()
        let newSocket = fixture.factory.sockets[1]
        newSocket.open()
        newSocket.completeSend()
        let taskID = try fixture.taskID(socket: newSocket)
        try fixture.emit("task-started", socket: newSocket, taskID: taskID)
        oldSocket.completeSend()
        oldSocket.fail()
        oldDeadlines.forEach { $0() }
        fixture.client.sendAudio(Data([3, 4]))
        XCTAssertEqual(newSocket.binary, [Data([3, 4])])
        XCTAssertEqual(newSocket.cancels, 0)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        fixture.client.cancel()
    }

    func testInvalidConfiguration_NeverCreatesConnection() {
        let factory = AssemblyAISocketFactory()
        var errors: [Error] = []
        let client = AlibabaFunASRLiveClient(credentials: "bare-key", makeConnection: { factory.make($0) })
        client.start(onTranscript: { _, _ in XCTFail("Unexpected text") }, onError: { errors.append($0) })
        XCTAssertTrue(factory.sockets.isEmpty)
        XCTAssertEqual(errors.last as? AlibabaSpeechError, .configuration)
    }

    func testCancel_ResolvesWaitingFinishWithoutACompletion() async throws {
        let fixture = try AlibabaLiveFixture()
        try fixture.ready()
        let finishSent = expectation(description: "finish-task")
        fixture.socket.onSend = { message in
            if case .text(let text) = message, text.contains("finish-task") { finishSent.fulfill() }
        }
        let result = Task { await fixture.client.finishAndWait() }
        await fulfillment(of: [finishSent], timeout: 2)
        result.cancel()
        let whole = await result.value
        XCTAssertNil(whole)
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
    }
}

private final class AlibabaLiveFixture: @unchecked Sendable {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let client: AlibabaFunASRLiveClient
    var socket: AssemblyAITestSocket { factory.sockets[0] }

    init(onSchedule: (@Sendable (TimeInterval, AssemblyAITestClock) -> Void)? = nil) throws {
        let credentials = try AlibabaSpeechConfiguration(
            region: .singapore, workspace: "llm-example", apiKey: "synthetic"
        ).encodedCredentials()
        let factory = factory, clock = clock
        client = AlibabaFunASRLiveClient(
            credentials: credentials, makeConnection: { factory.make($0) },
            schedule: { seconds, action in
                clock.schedule(seconds, action: action)
                onSchedule?(seconds, clock)
            }
        )
    }

    func start() {
        client.start(onTranscript: { [events] in events.transcript($0, final: $1) },
                     onError: { [events] in events.fail($0) })
    }

    func ready() throws {
        start()
        socket.open()
        socket.completeSend()
        try emit("task-started")
    }

    func control(socket: AssemblyAITestSocket? = nil) throws -> [String: Any] {
        let text = try XCTUnwrap((socket ?? self.socket).controls.first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func taskID(socket: AssemblyAITestSocket? = nil) throws -> String {
        let header = try XCTUnwrap(control(socket: socket)["header"] as? [String: Any])
        return try XCTUnwrap(header["task_id"] as? String)
    }

    func emit(
        _ event: String, socket: AssemblyAITestSocket? = nil, taskID: String? = nil, errorCode: String? = nil,
        sentence: [String: Any]? = nil
    ) throws {
        var header: [String: Any] = ["event": event, "task_id": try taskID ?? self.taskID(socket: socket)]
        if let errorCode { header["error_code"] = errorCode }
        var object: [String: Any] = ["header": header]
        if let sentence { object["payload"] = ["output": ["sentence": sentence]] }
        let text = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        (socket ?? self.socket).emit(text)
    }

    func sentence(_ text: String, id: Int, final: Bool) throws {
        try emit("result-generated", sentence: [
            "text": text, "sentence_id": id, "sentence_end": final,
            "begin_time": id * 1_000, "end_time": (id + 1) * 1_000
        ])
    }
}
