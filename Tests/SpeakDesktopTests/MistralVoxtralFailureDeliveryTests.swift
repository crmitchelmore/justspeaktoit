import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

/// A failure is published before any finish of that run returns: a finish
/// registered before the failure, and one that joins after the run was
/// retired but while its error is still being delivered on the transport's
/// thread. Delivery itself runs outside the state lock, so a callback may
/// start a replacement, which the failed run's waiters and deadlines never touch.
final class MistralVoxtralFailureDeliveryTests: XCTestCase {
    private typealias Fixture = MistralVoxtralLiveFixture
    private let budget = MistralVoxtralRealtime.finishBudget

    func testAFinishJoiningWhileTheFailureIsBeingDeliveredWaitsForIt() async {
        let factory = AssemblyAISocketFactory()
        let client = MistralVoxtralLiveClient(
            apiKey: "synthetic", makeConnection: { factory.make($0) }, schedule: { _, _ in }
        )
        let gate = MistralDeliveryGate()
        let entered = expectation(description: "Error delivery began on the transport's thread")
        client.start(onTranscript: { _, _ in }, onError: { _ in
            entered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            gate.markDelivered()
        })
        let socket = factory.sockets[0]
        Self.stream("Heard", on: socket, into: client)
        DispatchQueue.global().async { socket.fail() }
        await fulfillment(of: [entered], timeout: 2)
        let early = expectation(description: "Finish cannot return before the failure is delivered")
        early.isInverted = true
        let returned = expectation(description: "Finish returned after the failure was delivered")
        let finish = Task {
            let transcript = await client.finishAndWait()
            if !gate.delivered { early.fulfill() }
            returned.fulfill()
            return transcript
        }
        await fulfillment(of: [early], timeout: 0.2)
        await Self.settle { client.finishWaiterCount == 1 }
        XCTAssertEqual(client.finishWaiterCount, 1, "The late finish joined the failed run's delivery")
        gate.release.signal()
        await fulfillment(of: [returned], timeout: 2)
        let transcript = await finish.value
        XCTAssertEqual(transcript, "Heard")
    }

    func testRegisteredAndLateFinishesBothWaitWhileAReplacementStaysIsolated() async {
        let factory = AssemblyAISocketFactory()
        let clock = AssemblyAITestClock()
        let client = MistralVoxtralLiveClient(
            apiKey: "synthetic", makeConnection: { factory.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
        let gate = MistralDeliveryGate()
        let entered = expectation(description: "Error delivery began on the transport's thread")
        client.start(onTranscript: { _, _ in }, onError: { _ in
            entered.fulfill()
            XCTAssertEqual(gate.release.wait(timeout: .now() + 3), .success)
            client.start(onTranscript: { _, _ in }, onError: { _ in XCTFail("Old cleanup failed the replacement") })
            gate.markDelivered()
        })
        let old = factory.sockets[0]
        Self.stream("Saved.", on: old, into: client)
        let registered = Task { (await client.finishAndWait(), gate.delivered) }
        await Self.settle { clock.pending(self.budget) == 1 }
        old.completeSend()
        DispatchQueue.global().async { old.fail() }
        await fulfillment(of: [entered], timeout: 2)
        let late = Task { (await client.finishAndWait(), gate.delivered) }
        await Self.settle { client.finishWaiterCount == 2 }
        XCTAssertEqual(client.finishWaiterCount, 2, "Both finishes wait on the failed run")
        let oldDeadlines = clock.drain()
        gate.release.signal()
        let first = await registered.value
        let second = await late.value
        XCTAssertEqual(first.0, "Saved.")
        XCTAssertEqual(second.0, "Saved.")
        XCTAssertTrue(first.1 && second.1, "Neither finish returned before the failure was delivered")
        oldDeadlines.forEach { $0() }
        XCTAssertEqual(factory.sockets.count, 2)
        let replacement = factory.sockets[1]
        XCTAssertEqual(replacement.cancels, 0, "The failed run's cleanup never touches the replacement")
        replacement.open()
        replacement.sessionCreated()
        replacement.completeSend()
        client.sendAudio(Fixture.frame(1))
        XCTAssertEqual(replacement.appendedAudio, [Fixture.frame(1)])
        client.cancel()
    }

    func testADesktopSessionCannotReportSuccessBeforeTheFailureIsDelivered() async {
        let socket = MistralHeldCancelSocket()
        let client = MistralVoxtralLiveClient(
            apiKey: "synthetic", makeConnection: { _ in socket }, schedule: { _, _ in }
        )
        let session = DesktopLiveSession(client: client)
        session.start()
        socket.open()
        socket.emit(#"{"type":"session.created"}"#)
        socket.completeSend()
        session.sendAudio(Fixture.frame(0))
        socket.emit(#"{"type":"transcription.text.delta","text":"Heard"}"#)
        socket.holdNextCancel()
        DispatchQueue.global().async { socket.failReceive() }
        XCTAssertEqual(socket.cancelEntered.wait(timeout: .now() + 2), .success, "The failed run is retiring")
        let finished = Task { await session.finish() }
        await Self.settle { client.finishWaiterCount == 1 }
        socket.cancelRelease.signal()
        let snapshot = await finished.value
        XCTAssertEqual(snapshot.phase, .failed, "The host must not record a success before the failure")
        XCTAssertNotNil(snapshot.error)
        XCTAssertEqual(snapshot.text, "Heard")
    }
}

private extension MistralVoxtralFailureDeliveryTests {
    /// Configures the session, admits one frame and hears `text`.
    static func stream(_ text: String, on socket: AssemblyAITestSocket, into client: MistralVoxtralLiveClient) {
        socket.open()
        socket.sessionCreated()
        socket.completeSend()
        client.sendAudio(Fixture.frame(0))
        socket.delta(text)
    }

    /// Waits for a condition another thread drives, bounded, without a fixed
    /// sleep on the healthy path.
    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class MistralDeliveryGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveredValue = false
    var delivered: Bool { lock.withLock { deliveredValue } }
    func markDelivered() { lock.withLock { deliveredValue = true } }
}

/// A transport whose next `cancel()` blocks on the calling thread until the
/// test releases it, so the retiring run's error delivery is observably
/// pending while a host finishes.
private final class MistralHeldCancelSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var opener: (@Sendable () -> Void)?
    private var receiver: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var completions: [@Sendable (Error?) -> Void] = []
    private var holdsCancel = false
    let cancelEntered = DispatchSemaphore(value: 0)
    let cancelRelease = DispatchSemaphore(value: 0)

    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { opener = onOpen } }

    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { completions.append(completion) }
    }

    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }

    func cancel() {
        let held: Bool = lock.withLock {
            defer { holdsCancel = false }
            return holdsCancel
        }
        guard held else { return }
        cancelEntered.signal()
        cancelRelease.wait()
    }

    func holdNextCancel() { lock.withLock { holdsCancel = true } }
    func open() { lock.withLock { opener }?() }
    func emit(_ text: String) { deliver(.success(.text(text))) }
    func failReceive() { deliver(.failure(URLError(.networkConnectionLost))) }

    func completeSend() {
        let callback = lock.withLock { completions.removeFirst() }
        callback(nil)
    }

    private func deliver(_ result: Result<StreamingWebSocketMessage, Error>) {
        let callback: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)? = lock.withLock {
            defer { receiver = nil }
            return receiver
        }
        callback?(result)
    }
}
