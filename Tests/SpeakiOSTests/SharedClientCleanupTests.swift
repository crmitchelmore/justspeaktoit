#if os(iOS)
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
