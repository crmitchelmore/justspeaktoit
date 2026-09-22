import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// Failure delivery, re-entrancy and per-run identity of the shared Rev.ai
/// client. Callbacks run outside the state lock, so each test also proves the
/// client can be re-entered from inside one without deadlocking.
final class RevAIFailureDeliveryTests: XCTestCase {
    func testFailureDelivery_precedesRegisteredAndLateFinishes_andMayStartAnUntouchedReplacement() async {
        let fixture = RevAILiveFixture()
        let client = fixture.client
        let gate = RevAIDeliveryGate()
        let replaced = expectation(description: "Replacement started from onError")
        client.start(onTranscript: { _, _ in }, onError: { _ in
            gate.hold()
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Old cleanup failed the replacement") })
            gate.markDelivered()
            replaced.fulfill()
        })
        let old = fixture.socket
        fixture.becomeReady()
        fixture.stream([RevAILiveFixture.frame(0)])
        old.finalHypothesis("Saved.")
        let endOfStream = expectation(description: "EOS handed to the transport")
        old.fulfillOnEndOfStream(endOfStream)
        let registered = Task { (await client.finishAndWait(), gate.delivered) }
        await fulfillment(of: [endOfStream], timeout: 2)
        DispatchQueue.global().async { old.fail() }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(old.cancels, 1, "The failing run is closed before its error is delivered")
        // A new finish arrives while delivery is suspended outside the lock.
        let late = Task { (await client.finishAndWait(), gate.delivered) }
        await fixture.settle { client.finishWaiterCount == 2 }
        XCTAssertFalse(gate.delivered)
        gate.release.signal()
        await fulfillment(of: [replaced], timeout: 2)
        let registeredOutcome = await registered.value
        let lateOutcome = await late.value
        XCTAssertEqual(registeredOutcome.0, "Saved.")
        XCTAssertTrue(registeredOutcome.1, "A registered finish returned before onError")
        XCTAssertEqual(lateOutcome.0, "Saved.")
        XCTAssertTrue(lateOutcome.1, "A late finish returned before onError")
        XCTAssertEqual(old.cancels, 1)
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        let replacement = fixture.factory.sockets[1]
        replacement.open()
        replacement.connected()
        client.sendAudio(RevAILiveFixture.frame(1))
        XCTAssertEqual(replacement.binary, [RevAILiveFixture.frame(1)])
        XCTAssertEqual(replacement.cancels, 0)
        client.cancel()
    }

    /// The host-level reproduction: a finish that joins while the error is
    /// being delivered must leave the session failed, never recorded as a
    /// success whose failure then arrives too late to count.
    func testDesktopSession_keepsTheFailureWhenItsFinishJoinsDuringDelivery() async {
        let fixture = RevAILiveFixture()
        let gate = RevAIDeliveryGate()
        let session = DesktopLiveSession(client: RevAIGatedFailureClient(fixture.client, gate: gate))
        session.start()
        let socket = fixture.socket
        fixture.becomeReady()
        session.sendAudio(RevAILiveFixture.frame(0))
        socket.completeSend()
        socket.partialHypothesis(["draft", "words"])
        DispatchQueue.global().async { socket.fail() }
        await fulfillment(of: [gate.entered], timeout: 2)
        let finish = Task { await session.finish() }
        await fixture.settle { fixture.client.finishWaiterCount == 1 }
        gate.release.signal()
        let snapshot = await finish.value
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertNotNil(snapshot.error)
        XCTAssertEqual(snapshot.text, "draft words", "The visible draft stays the recovery text")
    }

    func testCallbacks_mayReenterCancelSendStartAndFinish_withoutDeadlock() async {
        let fixture = RevAILiveFixture()
        let client = fixture.client
        let spawned = RevAISpawnedFinish()
        let delivered = expectation(description: "onError returned")
        client.start(onTranscript: { text, _ in
            if text == "Cancel now." { client.sendAudio(RevAILiveFixture.frame(7)) }
        }, onError: { _ in
            client.stop()
            client.sendAudio(RevAILiveFixture.frame(8))
            spawned.task = Task { await client.finishAndWait() }
            // The finish can register only if no lock is held across this callback.
            let deadline = Date().addingTimeInterval(2)
            while client.finishWaiterCount == 0, Date() < deadline { usleep(1_000) }
            XCTAssertEqual(client.finishWaiterCount, 1)
            client.start(onTranscript: { _, _ in }, onError: { _ in })
            delivered.fulfill()
        })
        fixture.becomeReady()
        fixture.socket.finalHypothesis("Cancel now.")
        XCTAssertEqual(fixture.socket.binary, [RevAILiveFixture.frame(7)], "onTranscript may send audio")
        fixture.socket.completeSend()
        let socket = fixture.socket
        DispatchQueue.global().async { socket.peerClose(4_003) }
        await fulfillment(of: [delivered], timeout: 3)
        let joined = await spawned.task?.value
        XCTAssertEqual(joined, "Cancel now.")
        XCTAssertEqual(fixture.socket.binary, [RevAILiveFixture.frame(7)], "The failed run sends nothing more")
        XCTAssertEqual(fixture.factory.sockets.count, 2)
        client.cancel()
    }

    func testCancelAndReplacement_wakeEveryFinishWithConfirmedTextAndNoError() async {
        let fixture = RevAILiveFixture()
        let client = fixture.client
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(RevAILiveFixture.frame(0))
        fixture.socket.finalHypothesis("Heard.")
        fixture.socket.partialHypothesis(["not", "confirmed"])
        let first = Task { await client.finishAndWait() }
        let second = Task { await client.finishAndWait() }
        await fixture.settle { client.finishWaiterCount == 2 }
        client.cancel()
        let results = [await first.value, await second.value]
        XCTAssertEqual(results, ["Heard.", "Heard."], "A cancelled finish returns confirmed words only")
        XCTAssertTrue(fixture.events.errors.isEmpty)
        XCTAssertEqual(fixture.socket.cancels, 1)

        let replacing = RevAILiveFixture()
        replacing.start()
        replacing.becomeReady()
        replacing.client.sendAudio(RevAILiveFixture.frame(0))
        let waiting = Task { await replacing.client.finishAndWait() }
        await replacing.settle { replacing.client.finishWaiterCount == 1 }
        replacing.client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("The replacement must not fail") })
        let abandoned = await waiting.value
        XCTAssertNil(abandoned)
        XCTAssertEqual(replacing.socket.cancels, 1)
        XCTAssertEqual(replacing.factory.sockets[1].cancels, 0)
        replacing.client.cancel()
    }

    func testTaskCancellation_abortsTheFinishAndClosesTheRun() async {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        fixture.client.sendAudio(RevAILiveFixture.frame(0))
        fixture.socket.finalHypothesis("Partial session.")
        let client = fixture.client
        let finish = Task { await client.finishAndWait() }
        await fixture.settle { client.finishWaiterCount == 1 }
        finish.cancel()
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Partial session.")
        XCTAssertEqual(fixture.socket.cancels, 1)
        XCTAssertTrue(fixture.events.errors.isEmpty)
        let precancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.finishAndWait()
        }
        let repeated = await precancelled.value
        XCTAssertEqual(repeated, "Partial session.")
    }

    func testLateEventsFromARetiredRun_changeNothingInItsReplacement() {
        let fixture = RevAILiveFixture()
        fixture.start()
        fixture.becomeReady()
        let old = fixture.socket
        fixture.client.sendAudio(RevAILiveFixture.frame(0))
        let oldDeadlines = fixture.clock.drain()
        fixture.start()
        let replacement = fixture.factory.sockets[1]
        XCTAssertEqual(old.cancels, 1)
        old.finalHypothesis("Stale.")
        old.completeSend()
        old.peerClose(4_003)
        oldDeadlines.forEach { $0() }
        XCTAssertTrue(fixture.events.texts.isEmpty, "A retired run delivers nothing")
        XCTAssertTrue(fixture.events.errors.isEmpty, "A retired run fails nothing")
        replacement.open()
        replacement.connected()
        fixture.client.sendAudio(RevAILiveFixture.frame(1))
        XCTAssertEqual(replacement.binary, [RevAILiveFixture.frame(1)])
        XCTAssertEqual(fixture.client.bufferedAudioFrames, 1, "An old completion released nothing here")
        XCTAssertEqual(replacement.cancels, 0)
        XCTAssertEqual(fixture.factory.sockets.count, 2, "Nothing reconnects")
        fixture.client.cancel()
    }

    func testFactoryReturningAfterRetirement_isCancelledAndNeverResumed() {
        let box = RevAIClientBox()
        let recorded = RevAIResumeRecordingSocket()
        let client = RevAILiveClient(accessToken: "synthetic-token", makeConnection: { _ in
            box.client?.cancel()
            return recorded
        }, schedule: { _, _ in })
        box.client = client
        client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("A cancelled start publishes nothing") })
        XCTAssertEqual(recorded.resumeCount, 0)
        XCTAssertEqual(recorded.receiveCount, 0)
        XCTAssertEqual(recorded.inner.cancels, 1)
        client.sendAudio(RevAILiveFixture.frame(0))
        XCTAssertTrue(recorded.inner.binary.isEmpty)
    }

    func testStartedRunWhoseFactoryIsStillReturning_isNotTreatedAsSocketFree() async {
        let factory = AssemblyAISocketFactory()
        let clock = AssemblyAITestClock()
        let entered = expectation(description: "Transport factory entered")
        let release = DispatchSemaphore(value: 0)
        let client = RevAILiveClient(accessToken: "synthetic-token", makeConnection: { request in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return factory.make(request)
        }, schedule: { clock.schedule($0, action: $1) })
        let started = expectation(description: "start returned")
        DispatchQueue.global().async {
            client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected failure: \($0)") })
            started.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        client.sendAudio(RevAILiveFixture.frame(0))
        let finish = Task { await client.finishAndWait() }
        await RevAILiveFixture.settle { client.finishWaiterCount == 1 }
        XCTAssertEqual(client.bufferedAudioFrames, 1, "The finish kept the started run's capture")
        release.signal()
        await fulfillment(of: [started], timeout: 2)
        let socket = factory.sockets[0]
        socket.open()
        socket.connected()
        XCTAssertEqual(socket.binary, [RevAILiveFixture.frame(0)])
        socket.completeSend()
        XCTAssertEqual(socket.endOfStreamFrames, ["EOS"])
        socket.completeSend()
        socket.finalHypothesis("Kept.")
        socket.peerClose(1_000)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Kept.")
    }
}

/// Holds a host's error delivery open until the test releases it.
final class RevAIDeliveryGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "onError entered")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }

    func hold() {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
    }

    func markDelivered() { lock.withLock { deliveredValue = true } }
}

/// The real client with a host whose error handling is slow: `onError` waits
/// at the gate before the host sees the failure.
private final class RevAIGatedFailureClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    private let inner: RevAILiveClient
    private let gate: RevAIDeliveryGate
    var finalShape: TranscriptFinalShape { inner.finalShape }

    init(_ inner: RevAILiveClient, gate: RevAIDeliveryGate) {
        self.inner = inner
        self.gate = gate
    }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        inner.start(onTranscript: onTranscript, onError: { [gate] error in
            gate.hold()
            onError(error)
            gate.markDelivered()
        })
    }

    func sendAudio(_ audioData: Data) { inner.sendAudio(audioData) }
    func stop() { inner.stop() }
    func cancel() { inner.cancel() }
    func finishAndWait() async -> String? { await inner.finishAndWait() }
}

private final class RevAISpawnedFinish: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<String?, Never>?
    var task: Task<String?, Never>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class RevAIClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RevAILiveClient?
    var client: RevAILiveClient? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Records whether the client ever resumed or read from a connection.
private final class RevAIResumeRecordingSocket: StreamingWebSocketConnection, @unchecked Sendable {
    let inner = AssemblyAITestSocket()
    private let lock = NSLock()
    private var resumes = 0
    private var receives = 0
    var resumeCount: Int { lock.withLock { resumes } }
    var receiveCount: Int { lock.withLock { receives } }

    func resume(onOpen: @escaping @Sendable () -> Void) {
        lock.withLock { resumes += 1 }
        inner.resume(onOpen: onOpen)
    }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        inner.send(message, completion: completion)
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receives += 1 }
        inner.receive(completion: completion)
    }

    func cancel() { inner.cancel() }
}
