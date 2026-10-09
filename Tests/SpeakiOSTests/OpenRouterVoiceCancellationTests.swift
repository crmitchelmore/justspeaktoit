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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
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
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = {
            cancellation.record()
            stopped.fulfill()
        }
        defer { StubURLProtocol.reset() }
        let client = OpenRouterIOSVoiceOutputClient(session: session)
        let task = startSpeech(on: client, completed: completed)
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 2)
        if cancelCaller {
            task.cancel()
            if keepMainActorBusy {
                assertTransportCancelledWithoutYieldingMainActor(cancellation)
            }
        } else {
            client.stop()
        }
        await fulfillment(of: [stopped, completed], timeout: 2)
        XCTAssertFalse(client.isSpeaking)
    }

    private func startSpeech(
        on client: OpenRouterIOSVoiceOutputClient, completed: XCTestExpectation
    ) -> Task<Void, Never> {
        Task {
            defer { completed.fulfill() }
            do {
                try await client.speak(
                    text: "Hello",
                    apiKey: "test-key",
                    selectionID: OpenRouterSpeechSelection(modelID: "example/speech", voice: "voice").id,
                    speed: 1
                )
                XCTFail("Stopping synthesis must cancel the operation")
            } catch {
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
