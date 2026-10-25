import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakApp

@MainActor
final class AzureProxyHealthBoundsTests: XCTestCase {
    func testHealthReplyAtLimit_remainsValid() async throws {
        let json = Data(#"{"status":"ready","scope":"batch-transcription-and-tts"}"#.utf8)
        let body = json + Data(repeating: 32, count: 4_096 - json.count)
        let result = await validate(body: body, declaredLength: body.count, finishes: true)
        XCTAssertEqual(result.outcome, .success(
            message: "Local proxy connected for transcription only. "
                + "Azure sign-in and model access are checked when recording."
        ))
    }

    func testDeclaredOversize_isRejectedAndTransportCancelled() async {
        await assertOversize(body: Data(), declaredLength: 4_097)
    }

    func testUndeclaredOversize_isRejectedAndTransportCancelled() async {
        await assertOversize(body: Data(repeating: 32, count: 4_097), declaredLength: nil)
    }

    func testUnfinishedPartialResponse_deadlineCancelsTransport() async {
        let stopped = expectation(description: "Partial health response cancelled")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let result = await validate(body: Data(#"{"status":"#.utf8), declaredLength: nil, finishes: false)
        XCTAssertEqual(result.outcome, .failure(
            message: "The local proxy health check timed out. Check the proxy and try again."
        ))
        await fulfillment(of: [stopped], timeout: 3)
    }

    private func assertOversize(body: Data, declaredLength: Int?) async {
        let stopped = expectation(description: "Oversized health response cancelled")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let result = await validate(body: body, declaredLength: declaredLength, finishes: false)
        XCTAssertEqual(result.outcome, .failure(
            message: "The local proxy health response exceeds the 4 KB limit."
        ))
        await fulfillment(of: [stopped], timeout: 3)
    }

    private func validate(body: Data, declaredLength: Int?, finishes: Bool) async -> APIKeyValidationResult {
        let endpointKey = AzureSpeechConfiguration.endpointDefaultsKey
        let previous = UserDefaults.standard.object(forKey: endpointKey)
        UserDefaults.standard.set("http://127.0.0.1:8765", forKey: endpointKey)
        defer { UserDefaults.standard.set(previous, forKey: endpointKey) }
        StubURLProtocol.handler = { request in
            var headers = ["Content-Type": "application/json"]
            if let declaredLength { headers["Content-Length"] = String(declaredLength) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers
            )!
            return finishes ? .respond(response, body) : .respondWithoutFinishing(response, body)
        }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        return await AzureTranscriptionProvider(session: session, localProxyHealthDeadline: .milliseconds(200))
            .validateAPIKey("local-proxy/" + String(repeating: "a", count: 43))
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }
}
