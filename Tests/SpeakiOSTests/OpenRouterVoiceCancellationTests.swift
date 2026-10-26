#if os(iOS)
import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakiOSLib

@MainActor
final class OpenRouterVoiceCancellationTests: XCTestCase {
    func testStopCancelsPendingSynthesisBeforePlayback() async throws {
        try await assertPendingSynthesisIsCancelled(afterResponse: false, cancelCaller: false)
    }

    func testCallerCancellationCancelsPendingSynthesisBeforePlayback() async throws {
        try await assertPendingSynthesisIsCancelled(afterResponse: false, cancelCaller: true)
    }

    func testCallerCancellationCancelsTransportWhileMainActorIsBusy() async throws {
        try await assertPendingSynthesisIsCancelled(afterResponse: false, cancelCaller: true, keepMainActorBusy: true)
    }

    func testCallerCancellationCancelsPartialSynthesisBeforePlayback() async throws {
        try await assertPendingSynthesisIsCancelled(afterResponse: true, cancelCaller: true)
    }

    func testStopCancelsPartialSynthesisBeforePlayback() async throws {
        try await assertPendingSynthesisIsCancelled(afterResponse: true, cancelCaller: false)
    }

    private func assertPendingSynthesisIsCancelled(
        afterResponse: Bool, cancelCaller: Bool, keepMainActorBusy: Bool = false
    ) async throws {
        let started = expectation(description: "Speech request started")
        let stopped = expectation(description: "Speech request cancelled")
        let completed = expectation(description: "Synthesis caller cancelled promptly")
        let cancellation = TransportCancellationObservation()
        let diagnostics = SpeechCancellationDiagnostics()
        let failuresBefore = testRun?.failureCount ?? 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: diagnostics, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        installSpeechResponse(afterResponse: afterResponse)
        StubURLProtocol.onStartLoading = {
            diagnostics.record(.protocolOutcomeDelivered)
            started.fulfill()
        }
        StubURLProtocol.onStopLoading = {
            diagnostics.record(.protocolStopLoading)
            cancellation.record()
            stopped.fulfill()
        }
        defer { StubURLProtocol.reset() }
        let client = OpenRouterIOSVoiceOutputClient(session: session)
        let task = startSpeech(on: client, completed: completed, diagnostics: diagnostics)
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 2)
        diagnostics.record(.protocolStartWaitReturned)
        if cancelCaller {
            diagnostics.record(.callerCancelRequested)
            task.cancel()
            if keepMainActorBusy {
                assertTransportCancelledWithoutYieldingMainActor(cancellation)
            }
        } else {
            diagnostics.record(.clientStopRequested)
            client.stop()
        }
        await fulfillment(of: [stopped, completed], timeout: 2)
        XCTAssertFalse(client.isSpeaking)
        await attachDiagnosticsIfFailed(session, diagnostics: diagnostics, failuresBefore: failuresBefore)
    }

    private func installSpeechResponse(afterResponse: Bool) {
        StubURLProtocol.handler = {  request in
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            XCTAssertEqual(request.url?.path, "/api/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            if afterResponse {
                return .respondWithoutFinishing(
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "audio/mpeg"]
                    )!,
                    Data("ID3".utf8)
                )
            }
            return .hang
        }
    }

    private func attachDiagnosticsIfFailed(
        _ session: URLSession, diagnostics: SpeechCancellationDiagnostics, failuresBefore: Int
    ) async {
        guard (testRun?.failureCount ?? 0) > failuresBefore else { return }
        // Observe only after the original assertions; never delay or synchronize cancellation.
        // Task-specific delegates can intercept callbacks, so absence of a delegate event is unknown.
        let sampled = expectation(description: "Post-failure owned-session task snapshot")
        session.getAllTasks { tasks in
            diagnostics.recordTasks(tasks)
            sampled.fulfill()
        }
        _ = await XCTWaiter.fulfillment(of: [sampled], timeout: 1)
        let attachment = XCTAttachment(string: diagnostics.snapshot())
        attachment.name = "Content-free speech cancellation phases"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func startSpeech(
        on client: OpenRouterIOSVoiceOutputClient, completed: XCTestExpectation,
        diagnostics: SpeechCancellationDiagnostics
    ) -> Task<Void, Never> {
        Task {
            defer { diagnostics.record(.callerReturned); completed.fulfill() }
            do {
                try await client.speak(
                    text: "Hello",
                    apiKey: "test-key",
                    selectionID: OpenRouterSpeechSelection(modelID: "example/speech", voice: "voice").id,
                    speed: 1
                )
                XCTFail("Stopping synthesis must cancel the operation")
            } catch {
                diagnostics.record(error is CancellationError ? .callerCancellationError : .callerOtherError)
                XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
            }
        }
    }

    private func assertTransportCancelledWithoutYieldingMainActor(_ observation: TransportCancellationObservation) {
        // Deliberately deny actor hops: cancelling network I/O must not queue behind UI work.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !observation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(observation.isCancelled, "Transport cancellation must not wait for a MainActor cleanup task")
    }
}

private final class TransportCancellationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func record() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

#endif
