#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class OpenRouterVoiceCancellationTests: XCTestCase {
    func testStopCancelsPendingSynthesisBeforePlayback() async throws {
        let started = expectation(description: "Speech request started")
        let stopped = expectation(description: "Speech request cancelled")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterPendingSpeechProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        OpenRouterPendingSpeechProtocol.onStart = { request in
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            XCTAssertEqual(request.url?.path, "/api/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            started.fulfill()
        }
        OpenRouterPendingSpeechProtocol.onStop = { stopped.fulfill() }
        defer {
            OpenRouterPendingSpeechProtocol.onStart = nil
            OpenRouterPendingSpeechProtocol.onStop = nil
        }
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

private final class OpenRouterPendingSpeechProtocol: URLProtocol {
    nonisolated(unsafe) static var onStart: (@Sendable (URLRequest) -> Void)?
    nonisolated(unsafe) static var onStop: (@Sendable () -> Void)?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onStart?(request)
    }

    override func stopLoading() {
        Self.onStop?()
    }
}
#endif
