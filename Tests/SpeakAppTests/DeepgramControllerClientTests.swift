import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

final class DeepgramControllerClientTests: XCTestCase {
    func testNovaFinishDrainsPCMAndIncludesAllTrailingFinalsOnce() async throws {
        try await assertTrailingFinals(model: "nova-3")
    }

    func testFluxFinishDrainsPCMAndIncludesAllTrailingTurnsOnce() async throws {
        try await assertTrailingFinals(model: "flux-general-en")
    }

    func testFailureKeepsVisibleDraftAndConfirmedTextAndReportsOnce() async throws {
        let fixture = DeepgramMacFixture(model: "nova-3")
        fixture.start()
        fixture.socket.emit(fixture.event("Confirmed.", final: true))
        fixture.socket.emit(fixture.event("draft", final: false))
        fixture.socket.fail()
        let result = await fixture.adapter.finishAndWait()
        XCTAssertEqual(result.text, "Confirmed. draft")
        XCTAssertEqual(result.confirmedText, "Confirmed.")
        XCTAssertNotNil(result.error)
        XCTAssertNotNil(fixture.adapter.takeFailureForReporting())
        XCTAssertNil(fixture.adapter.takeFailureForReporting())
        XCTAssertNotNil(fixture.adapter.snapshot.error)
    }

    func testFinishSendFailureRetainsNewTrailingFinalAndDraftExactlyOnce() async throws {
        let fixture = DeepgramMacFixture(model: "nova-3")
        fixture.start()
        fixture.socket.emit(fixture.event("Confirmed.", final: true))
        fixture.socket.emit(fixture.event("unfinished draft", final: false))
        let closeSent = expectation(description: "CloseStream send held")
        fixture.socket.onClose = { closeSent.fulfill() }
        let outcome = DeepgramMacOutcome()
        let settled = expectation(description: "Failed finish settled")
        let errorPublished = expectation(description: "Failure callback actually published")
        fixture.onError = { _ in
            errorPublished.fulfill()
            XCTAssertNotNil(fixture.adapter.snapshot.error, "Failure is captured before UI delivery")
            XCTAssertNil(outcome.value, "Failure is published before finish settles")
        }
        let pending = Task {
            outcome.store(await fixture.adapter.finishAndWait())
            settled.fulfill()
        }
        defer { pending.cancel(); fixture.adapter.stop() }
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.emit(fixture.event("New trailing final.", final: true))
        fixture.socket.completeSend(error: URLError(.networkConnectionLost))
        await fulfillment(of: [settled, errorPublished], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.text, "Confirmed. New trailing final. unfinished draft")
        XCTAssertEqual(result.confirmedText, "Confirmed. New trailing final.")
        XCTAssertNotNil(result.error)
        XCTAssertEqual(fixture.socket.cancels, 1)
    }

    func testHealthyMetadataWithoutNewFinalPreservesUnconfirmedDraft() async throws {
        let fixture = DeepgramMacFixture(model: "nova-3")
        fixture.start()
        fixture.socket.emit(fixture.event("Confirmed.", final: true))
        fixture.socket.emit(fixture.event("unconfirmed draft", final: false))
        let closeSent = expectation(description: "CloseStream admitted")
        fixture.socket.onClose = { closeSent.fulfill() }
        let outcome = DeepgramMacOutcome()
        let settled = expectation(description: "Unchanged confirmed session settled")
        let pending = Task {
            outcome.store(await fixture.adapter.finishAndWait())
            settled.fulfill()
        }
        defer { pending.cancel(); fixture.adapter.stop() }
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.emit(#"{"type":"Metadata"}"#)
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.text, "Confirmed. unconfirmed draft")
        XCTAssertEqual(result.confirmedText, "Confirmed.")
        XCTAssertNil(result.error)
    }

    func testCancelledOldFinishCannotChangeReplacementRecording() async throws {
        let old = DeepgramMacFixture(model: "nova-3")
        old.start()
        old.socket.emit(old.event("Old.", final: true))
        old.socket.emit(old.event("draft", final: false))
        let closeSent = expectation(description: "Old CloseStream admitted")
        old.socket.onClose = { closeSent.fulfill() }
        let outcome = DeepgramMacOutcome()
        let settled = expectation(description: "Old finish settled")
        let pending = Task {
            outcome.store(await old.adapter.finishAndWait())
            settled.fulfill()
        }
        defer { pending.cancel(); old.adapter.stop() }
        await fulfillment(of: [closeSent], timeout: 2)
        let replacement = DeepgramMacFixture(model: "nova-3")
        replacement.start()
        defer { replacement.adapter.stop() }
        replacement.socket.emit(replacement.event("Current.", final: true))
        old.adapter.stop()
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertTrue(result.error is CancellationError)
        XCTAssertEqual(result.text, "Old. draft")
        old.socket.emit(old.event("Stale.", final: true))
        XCTAssertEqual(replacement.adapter.snapshot.text, "Current.")
        XCTAssertEqual(replacement.socket.cancels, 0)
        XCTAssertEqual(old.socket.cancels, 1)
        XCTAssertEqual(old.adapter.snapshot.text, "Old. draft")
    }

    func testSilentFinishIsEmptyAndLateCallbacksCannotChangeSnapshot() async throws {
        let fixture = DeepgramMacFixture(model: "nova-3")
        fixture.start()
        let closeSent = expectation(description: "Silent CloseStream admitted")
        fixture.socket.onClose = { closeSent.fulfill() }
        let outcome = DeepgramMacOutcome()
        let settled = expectation(description: "Silent finish settled")
        let pending = Task {
            outcome.store(await fixture.adapter.finishAndWait())
            settled.fulfill()
        }
        defer { pending.cancel(); fixture.adapter.stop() }
        await fulfillment(of: [closeSent], timeout: 2)
        fixture.socket.completeSend()
        fixture.socket.emit(#"{"type":"Metadata"}"#)
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.confirmedText, "")
        XCTAssertNil(result.error)
        fixture.socket.emit(fixture.event("Late.", final: true))
        XCTAssertEqual(fixture.adapter.snapshot.text, "")
    }

    private func assertTrailingFinals(model: String) async throws {
        let fixture = DeepgramMacFixture(model: model)
        fixture.start()
        fixture.socket.emit(fixture.event("Yes.", final: true))
        fixture.socket.emit(fixture.event("Yes.", final: true))
        fixture.adapter.sendAudio(Data([1, 0]))
        fixture.adapter.sendAudio(Data([2, 0]))
        let closeSent = expectation(description: "CloseStream follows both completed PCM frames")
        fixture.socket.onClose = { closeSent.fulfill() }
        let outcome = DeepgramMacOutcome()
        let settled = expectation(description: "Trailing finish settled")
        let pending = Task {
            outcome.store(await fixture.adapter.finishAndWait())
            settled.fulfill()
        }
        defer { pending.cancel(); fixture.adapter.stop() }
        fixture.socket.completeSend()
        XCTAssertEqual(fixture.socket.binary, [Data([1, 0]), Data([2, 0])])
        XCTAssertTrue(fixture.socket.text.isEmpty)
        fixture.socket.completeSend()
        await fulfillment(of: [closeSent], timeout: 2)
        XCTAssertEqual(fixture.socket.text, [#"{"type":"CloseStream"}"#])
        fixture.socket.completeSend()
        fixture.socket.emit(fixture.event("Tail one.", final: true))
        fixture.socket.emit(fixture.event("Tail two.", final: true))
        XCTAssertNil(outcome.value, "First trailing final must not end the drain")
        if model.hasPrefix("flux-") { fixture.socket.fail() } else {
            fixture.socket.emit(#"{"type":"Metadata"}"#)
        }
        await fulfillment(of: [settled], timeout: 2)
        let result = try XCTUnwrap(outcome.value)
        XCTAssertEqual(result.text, "Yes. Yes. Tail one. Tail two.")
        XCTAssertEqual(result.confirmedText, result.text)
        XCTAssertNil(result.error)
        XCTAssertEqual(fixture.delivered, ["Yes.", "Yes."], "Finish result replaces earlier live turns")
        XCTAssertEqual(fixture.socket.cancels, 1)
    }
}

private final class DeepgramMacFixture: @unchecked Sendable {
    let socket = DeepgramMacSocket()
    let adapter: DeepgramControllerClient
    let model: String
    private let lock = NSLock()
    private var transcripts: [String] = []
    var onError: ((Error) -> Void)?
    var delivered: [String] { lock.withLock { transcripts } }

    init(model: String) {
        self.model = model
        let socket = socket
        adapter = DeepgramControllerClient(client: DeepgramLiveClient(
            apiKey: "synthetic", model: model, makeConnection: { _ in socket }, schedule: { _, _ in }
        ))
    }

    func start() {
        adapter.start(onTranscript: { [weak self] text, _ in
            self?.lock.withLock { self?.transcripts.append(text) }
        }, onError: { [weak self] error in self?.onError?(error) })
        socket.open()
    }

    func event(_ text: String, final: Bool) -> String {
        if model.hasPrefix("flux-") {
            return #"{"type":"TurnInfo","event":""# + (final ? "EndOfTurn" : "Update")
                + #"","transcript":""# + text + #""}"#
        }
        return #"{"is_final":"# + String(final)
            + #", "channel":{"alternatives":[{"transcript":""# + text + #""}]}}"#
    }
}

private final class DeepgramMacOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: DeepgramControllerClient.Snapshot?
    var value: DeepgramControllerClient.Snapshot? { lock.withLock { result } }
    func store(_ value: DeepgramControllerClient.Snapshot) { lock.withLock { result = value } }
}

private final class DeepgramMacSocket: StreamingWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var opening: (@Sendable () -> Void)?
    private var receiveCallback: (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)?
    private var sends: [@Sendable (Error?) -> Void] = []
    private var messages: [StreamingWebSocketMessage] = []
    private var cancellations = 0
    var onClose: (@Sendable () -> Void)?
    var cancels: Int { lock.withLock { cancellations } }
    var binary: [Data] {
        lock.withLock { messages.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    }
    var text: [String] { lock.withLock { messages.compactMap { if case .text(let text) = $0 { text } else { nil } } } }
    func resume(onOpen: @escaping @Sendable () -> Void) { lock.withLock { opening = onOpen } }
    func open() { lock.withLock { opening }?() }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { messages.append(message); sends.append(completion) }
        if case .text = message { onClose?() }
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        lock.withLock { receiveCallback = completion }
    }
    func completeSend(error: Error? = nil) {
        let completion = lock.withLock { sends.isEmpty ? nil : sends.removeFirst() }
        XCTAssertNotNil(completion)
        completion?(error)
    }
    func emit(_ text: String) { deliver(.success(.text(text))) }
    func fail() { deliver(.failure(URLError(.networkConnectionLost))) }
    private func deliver(_ result: Result<StreamingWebSocketMessage, Error>) {
        let callback = lock.withLock { let callback = receiveCallback; receiveCallback = nil; return callback }
        callback?(result)
    }
    func cancel() { lock.withLock { cancellations += 1 } }
}
