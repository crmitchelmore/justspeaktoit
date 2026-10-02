#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
extension SharedClientCleanupTests {
    func testFailedFinish_preservesCumulativeDraftAndKeepsConfirmationSeparate() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        client.finalShape = .cumulativeTranscript
        transcriber.clientFactory = { client }
        try await transcriber.start()
        let displayed = expectation(description: "draft displayed")
        let failed = expectation(description: "failure delivered")
        transcriber.onPartialResult = { text, _ in
            if text == "Hello trailing words" { displayed.fulfill() }
        }
        transcriber.onError = { _ in failed.fulfill() }
        client.transcript?("Hello", true)
        client.transcript?("Hello trailing words", false)
        await fulfillment(of: [displayed], timeout: 2)
        transcriber.onPartialResult = nil
        client.failure?(StreamingClientError.transportStalled(provider: "test"))
        await fulfillment(of: [failed], timeout: 2)
        client.finish = { "Hello, revised." }
        let result = await transcriber.stop()
        XCTAssertEqual(result.text, "Hello trailing words")
        XCTAssertEqual(transcriber.partialText, "Hello trailing words")
        XCTAssertEqual(transcriber.finalText, "Hello, revised.")
        XCTAssertNotNil(transcriber.error)
    }

    func testFinishFailure_isDeliveredBeforeStopReturnsEvenWhenCallbackActorHopIsPending() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        transcriber.clientFactory = { client }
        var errors = 0
        transcriber.onError = { _ in errors += 1 }
        let delivery = ClientDeliveryQueue()
        transcriber.enqueueClientUpdate = { delivery.append($0) }
        try await transcriber.start()
        client.finish = {
            client.failure?(StreamingClientError.transportStalled(provider: "test"))
            return "Confirmed"
        }
        _ = await transcriber.stop()
        XCTAssertNotNil(transcriber.error)
        XCTAssertEqual(errors, 1)
        for callback in delivery.takeAll().reversed() { callback() }
        XCTAssertEqual(errors, 1, "queued error delivery must not repeat after stop")
    }

    func testCancel_usesAbortContractInsteadOfGracefulStop() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        transcriber.clientFactory = { client }
        try await transcriber.start()
        transcriber.cancel()
        await transcriber.awaitCancellationSettled()
        XCTAssertEqual(client.cancels, 1)
        XCTAssertEqual(client.stops, 1, "test client's abort keeps its existing stop counter")
    }

    func testHealthyFinish_replacesQueuedDraftAuthoritativelyWithoutDuplicatingSegments() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        let delivery = ClientDeliveryQueue()
        transcriber.enqueueClientUpdate = { delivery.append($0) }
        transcriber.clientFactory = { client }
        try await transcriber.start()
        client.transcript?("Yes.", true)
        client.transcript?("Yes.", true)
        client.transcript?("trailing draft", false)
        client.finish = { "Yes, yes!" }
        let result = await transcriber.stop()
        XCTAssertEqual(result.text, "Yes, yes!")
        XCTAssertEqual(transcriber.finalText, "Yes, yes!")
        for callback in delivery.takeAll().reversed() { callback() }
        XCTAssertEqual(transcriber.partialText, "Yes, yes!", "retired UI tasks cannot restore old drafts")
    }

    func testSynchronousStartupCallbacks_surviveResetAndFailureIsReportedOnce() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        let delivery = ClientDeliveryQueue()
        transcriber.enqueueClientUpdate = { delivery.append($0) }
        transcriber.clientFactory = { client }
        client.onStart = {
            client.transcript?("startup words", false)
            client.failure?(StreamingClientError.transportStalled(provider: "test"))
        }
        var errors = 0
        transcriber.onError = { _ in errors += 1 }
        try await transcriber.start()
        client.finish = { nil }
        let result = await transcriber.stop()
        XCTAssertEqual(result.text, "startup words")
        XCTAssertEqual(transcriber.finalText, "")
        XCTAssertNotNil(transcriber.error)
        XCTAssertEqual(errors, 1)
        for callback in delivery.takeAll() { callback() }
        XCTAssertEqual(errors, 1)
    }

    func testTaskCancellation_preservesDraftAndSeparatesLateConfirmation() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        client.finalShape = .cumulativeTranscript
        transcriber.clientFactory = { client }
        try await transcriber.start()
        client.transcript?("Hello trailing words", false)
        let finishing = expectation(description: "finishing")
        var complete: CheckedContinuation<String?, Never>?
        client.finish = { await withCheckedContinuation { complete = $0; finishing.fulfill() } }
        let stop = Task { await transcriber.stop() }
        await fulfillment(of: [finishing], timeout: 2)
        stop.cancel()
        complete?.resume(returning: "Hello, revised.")
        let result = await stop.value
        XCTAssertEqual(result.text, "Hello trailing words")
        XCTAssertEqual(transcriber.finalText, "Hello, revised.")
        XCTAssertEqual(client.cancels, 1)
    }

    func testActiveClientBudget_extendsForegroundWatchdogAndKeepsOtherDefaults() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        transcriber.clientFactory = { client }
        XCTAssertEqual(transcriber.stopCompletionTimeout, 10)
        try await transcriber.start()
        let invalidBudgets: [TimeInterval?] = [nil, 0, -1, .infinity, .nan]
        for invalid in invalidBudgets {
            client.finalisationBudget = invalid
            XCTAssertEqual(transcriber.stopCompletionTimeout, 10)
        }
        client.finalisationBudget = 8
        XCTAssertEqual(transcriber.stopCompletionTimeout, 10)
        client.finalisationBudget = 10
        XCTAssertEqual(transcriber.stopCompletionTimeout, 11)
        transcriber.cancel()
        await transcriber.awaitCancellationSettled()
    }

    func testCancelDuringFinish_abortUnblocksFinishAndPreservesFrozenDraft() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        client.finalShape = .cumulativeTranscript
        transcriber.clientFactory = { client }
        try await transcriber.start()
        client.transcript?("Hello trailing words", false)
        let finishing = expectation(description: "provider finishing")
        let completed = expectation(description: "abort released finish")
        var complete: CheckedContinuation<String?, Never>?
        client.finish = { await withCheckedContinuation { complete = $0; finishing.fulfill() } }
        client.onCancel = {
            client.transcript?("obsolete callback", true)
            client.failure?(CancellationError())
            complete?.resume(returning: "Hello")
            complete = nil
        }
        let stop = Task { let result = await transcriber.stop(); completed.fulfill(); return result }
        await fulfillment(of: [finishing], timeout: 2)
        transcriber.cancel()
        await fulfillment(of: [completed], timeout: 0.5)
        // Release a broken implementation too, so this regression fails instead of hanging.
        complete?.resume(returning: "Hello")
        complete = nil
        let result = await stop.value
        XCTAssertEqual(result.text, "Hello trailing words")
        XCTAssertEqual(transcriber.finalText, "", "explicit cancellation freezes confirmation too")
        XCTAssertNil(transcriber.error)
        XCTAssertEqual(client.cancels, 1)
    }

    func testElevenLabsBudget_comesFromActualClientAndSessionProjection() async throws {
        let manager = AudioSessionManager()
        manager.permissionStatus = { true }
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        let session = try IOSTranscriptionSession(
            modelID: "elevenlabs/scribe-v2-streaming", mode: .streaming,
            audioSessionManager: manager, batchAPIKey: "", liveAPIKey: { _ in "test-key" }
        )
        guard case .shared(let transcriber) = session.backend else { return XCTFail("missing shared backend") }
        // Keep transport and capture synthetic; use the actual client's declared budget.
        let actual: any FinalizingStreamingTranscriptionClient = ElevenLabsLiveClient(apiKey: "test-key")
        let client = CleanupTestClient()
        client.finalisationBudget = actual.finalisationBudget
        transcriber.clientFactory = { client }
        transcriber.startCaptureAudio = {}
        try await session.start()
        XCTAssertEqual(session.stopCompletionTimeout, 11)
        XCTAssertEqual(CaptureWatchdogPolicy.finalisationDeadlineSeconds(isBatch: false), 30)
        session.cancel()
        await session.awaitCancellationSettled()
    }
}

private final class ClientDeliveryQueue: @unchecked Sendable {
    typealias Callback = @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var callbacks: [Callback] = []
    func append(_ callback: @escaping Callback) { lock.withLock { callbacks.append(callback) } }
    func takeAll() -> [Callback] {
        lock.withLock { let pending = callbacks; callbacks.removeAll(); return pending }
    }
}
#endif
