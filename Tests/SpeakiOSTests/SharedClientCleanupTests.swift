#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class SharedClientCleanupTests: XCTestCase {
    func testCancellation_drainsAsynchronouslyOnceBeforeReleasingStartupOwnership() async throws {
        let manager = AudioSessionManager()
        manager.permissionStatus = { true }
        let configuring = expectation(description: "configuring")
        let draining = expectation(description: "draining queued work")
        let settled = expectation(description: "startup settled")
        var configurations = 0
        var releases = 0
        var drains = 0
        var finishDrain: CheckedContinuation<Void, Never>?
        manager.configureRecording = {
            configurations += 1
            _ = await CancellablePermissionRequest.request { _ in configuring.fulfill() }
            try Task.checkCancellation()
        }
        manager.deactivateRecording = { releases += 1 }
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "deepgram/nova-3-streaming"))
        let transcriber = SharedClientLiveTranscriber(route: route, apiKey: "test-key", audioSessionManager: manager)
        transcriber.drainCaptureWork = {
            drains += 1
            await withCheckedContinuation { continuation in
                finishDrain = continuation
                draining.fulfill()
            }
        }
        let start = Task { @MainActor in
            do {
                try await transcriber.start()
                XCTFail("cancelled startup activated")
            } catch { XCTAssertTrue(error is CancellationError) }
            settled.fulfill()
        }
        await fulfillment(of: [configuring], timeout: 2)
        transcriber.cancel()
        transcriber.cancel()
        await fulfillment(of: [draining], timeout: 2)
        XCTAssertEqual(releases, 0, "audio-session ownership must survive the pending drain")
        try await transcriber.start()
        transcriber.cancel()
        XCTAssertEqual(configurations, 1, "a replacement must not overlap cleanup")
        XCTAssertEqual(drains, 1)
        finishDrain?.resume()
        await fulfillment(of: [settled], timeout: 2)
        await start.value
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(transcriber.isRunning)
    }
    func testCancelledClientCallbacks_cannotChangeReplacementTranscriptOrError() async throws {
        let transcriber = try makeTranscriber()
        let oldClient = CleanupTestClient()
        let replacement = CleanupTestClient()
        var clients = [oldClient, replacement]
        transcriber.clientFactory = { clients.removeFirst() }
        try await transcriber.start()
        transcriber.cancel()
        try await transcriber.start() // waits for the old client's queued work
        let received = expectation(description: "replacement transcript")
        let staleCallback = expectation(description: "stale callback")
        staleCallback.isInverted = true
        transcriber.onPartialResult = { text, _ in
            if text == "replacement" { received.fulfill() } else { staleCallback.fulfill() }
        }
        transcriber.onError = { _ in staleCallback.fulfill() }
        oldClient.transcript?("cancelled words", true)
        oldClient.failure?(CancellationError())
        replacement.transcript?("replacement", true)
        await fulfillment(of: [received, staleCallback], timeout: 0.1)
        XCTAssertEqual(transcriber.partialText, "replacement")
        XCTAssertNil(transcriber.error)
        XCTAssertEqual(oldClient.stops, 1)
        XCTAssertEqual(replacement.stops, 0)
        transcriber.cancel()
        _ = await transcriber.stop()
    }

    func testCancelDuringGracefulStop_blocksReplacementUntilOldFinalisationReturns() async throws {
        let transcriber = try makeTranscriber()
        let oldClient = CleanupTestClient()
        let replacement = CleanupTestClient()
        var clients = [oldClient, replacement]
        transcriber.clientFactory = { clients.removeFirst() }
        let finishing = expectation(description: "waiting for provider finalisation")
        var finish: CheckedContinuation<String?, Never>?
        oldClient.finish = {
            await withCheckedContinuation { continuation in
                finish = continuation
                finishing.fulfill()
            }
        }
        try await transcriber.start()
        let stop = Task { @MainActor in await transcriber.stop() }
        await fulfillment(of: [finishing], timeout: 2)
        transcriber.cancel()
        try await transcriber.start()
        XCTAssertEqual(clients.count, 1, "old stop must retain ownership across its suspension")
        finish?.resume(returning: "cancelled final transcript")
        _ = await stop.value
        try await transcriber.start()
        XCTAssertTrue(clients.isEmpty)
        XCTAssertTrue(transcriber.isRunning)
        XCTAssertEqual(transcriber.partialText, "")
        XCTAssertEqual(replacement.stops, 0)
        transcriber.cancel()
        _ = await transcriber.stop()
    }

    func testEngineNotification_finishesOwnedCaptureOnceAndPreservesTranscript() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        var finishes = 0
        client.finish = { finishes += 1; return "captured final words" }
        transcriber.clientFactory = { client }
        try await transcriber.start()
        let stopped = expectation(description: "normal owner finalised")
        var errors = 0
        var resultText = ""
        transcriber.onError = { error in
            errors += 1
            XCTAssertEqual(error.localizedDescription, "The microphone changed and recording stopped.")
            Task { @MainActor in
                resultText = await transcriber.stop().text
                stopped.fulfill()
            }
        }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: transcriber.configurationNotificationObject
        )
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: transcriber.configurationNotificationObject
        )
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(resultText, "captured final words")
        XCTAssertFalse(transcriber.isRunning)
    }

    func testQueuedConfiguration_cancelAndReplacementIgnoreRetiredNotification() async throws {
        let transcriber = try makeTranscriber()
        transcriber.clientFactory = { CleanupTestClient() }
        try await transcriber.start()
        var errors = 0
        transcriber.onError = { _ in errors += 1 }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: transcriber.configurationNotificationObject
        )
        transcriber.cancel()
        try await transcriber.start()
        await Task { @MainActor in }.value
        XCTAssertEqual(errors, 0)
        XCTAssertTrue(transcriber.isRunning)
        transcriber.cancel()
        _ = await transcriber.stop()
    }

    func testInterruptionAndEngineChange_ownerReceivesOneStopAndWaitsForProviderTail() async throws {
        let transcriber = try makeTranscriber()
        let client = CleanupTestClient()
        transcriber.clientFactory = { client }
        let interrupted = expectation(description: "owner interrupted")
        let draining = expectation(description: "provider draining")
        var finish: CheckedContinuation<String?, Never>?
        var notices = 0
        client.finish = {
            await withCheckedContinuation {
                    finish = $0
                    draining.fulfill()
                }
        }
        transcriber.onError = { error in
            XCTAssertTrue((error as? iOSTranscriptionError)?.isControlledInterruption == true)
            notices += 1
            interrupted.fulfill()
        }
        try await transcriber.start()
        InterruptionSession.post(.began)
        await fulfillment(of: [interrupted], timeout: 2)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: transcriber.configurationNotificationObject
        )
        InterruptionSession.post(.began)
        InterruptionSession.post(.ended)
        XCTAssertNil(transcriber.error)
        XCTAssertEqual(client.stops, 0, "Provider must await its owner instead of competing to stop")
        let stop = Task { await transcriber.stop() }
        await fulfillment(of: [draining], timeout: 2)
        finish?.resume(returning: "Preserved provider tail")
        let result = await stop.value
        XCTAssertEqual(result.text, "Preserved provider tail")
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(client.stops, 1)
        XCTAssertFalse(transcriber.isRunning)
    }

    private func makeTranscriber() throws -> SharedClientLiveTranscriber {
        let manager = AudioSessionManager()
        manager.permissionStatus = { true }
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "deepgram/nova-3-streaming"))
        let transcriber = SharedClientLiveTranscriber(route: route, apiKey: "test-key", audioSessionManager: manager)
        transcriber.startCaptureAudio = {}
        return transcriber
    }

}
private final class CleanupTestClient: FinalizingStreamingTranscriptionClient {
    let finalShape: TranscriptFinalShape = .standaloneSegments
    let finishFlushesBufferedAudio = true
    var transcript: ((String, Bool) -> Void)?
    var failure: ((Error) -> Void)?
    var finish: (() async -> String?)?
    var stops = 0

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        transcript = onTranscript
        failure = onError
    }

    func sendAudio(_ audioData: Data) {}

    func stop() { stops += 1 }

    func finishAndWait() async -> String? { await finish?() }
}
#endif
