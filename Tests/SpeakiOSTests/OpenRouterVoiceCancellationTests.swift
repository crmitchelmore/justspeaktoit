#if os(iOS)
import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakiOSLib

@MainActor
final class OpenRouterVoiceCancellationTests: XCTestCase {
    func testStopCancelsPendingSynthesisBeforePlayback() async throws {
        let started = expectation(description: "Speech request started")
        let stopped = expectation(description: "Speech request cancelled")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StubURLProtocol.handler = {  request in
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            XCTAssertEqual(request.url?.path, "/api/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            started.fulfill()
            // The original stub sent no response at all, leaving the request
            // pending until the client cancels it.
            return .hang
        }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        defer { StubURLProtocol.reset() }
        let client = OpenRouterIOSVoiceOutputClient(session: session)
        let task = Task {
            try await client.speak(
                text: "Hello",
                apiKey: "test-key",
                selectionID: OpenRouterSpeechSelection(modelID: "example/speech", voice: "voice").id,
                speed: 1
            )
        }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 2)
        client.stop()
        await fulfillment(of: [stopped], timeout: 2)
        do {
            try await task.value
            XCTFail("Stopping synthesis must cancel the operation")
        } catch {
            XCTAssertFalse(client.isSpeaking)
        }
    }
}

#endif
