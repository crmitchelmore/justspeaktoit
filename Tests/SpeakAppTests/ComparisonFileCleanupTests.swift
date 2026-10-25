import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp
@testable import SpeakCore

@MainActor
final class ComparisonFileCleanupTests: XCTestCase {
    func testGladiaDeadlineDeletesOnlyAcceptedJob() async throws {
        try await assertDeadlineCleanup(
            model: GladiaBatchClient.catalogID,
            expectedDeletes: ["/v2/pre-recorded/job-owned"],
            expectedWork: ["POST /v2/upload", "POST /v2/pre-recorded", "GET /v2/pre-recorded/job-owned"]
        )
    }

    func testSpeechmaticsDeadlineDeletesOnlyAcceptedJob() async throws {
        try await assertDeadlineCleanup(
            model: SpeechmaticsBatchClient.standardCatalogID,
            expectedDeletes: ["/v2/jobs/job-owned"],
            expectedWork: ["POST /v2/jobs", "GET /v2/jobs/job-owned"]
        )
    }

    func testSonioxDeadlineDeletesOnlyAcceptedJobAndFile() async throws {
        try await assertDeadlineCleanup(
            model: "soniox/stt-async-v5",
            expectedDeletes: ["/v1/transcriptions/job-owned", "/v1/files/file-owned"],
            expectedWork: ["POST /v1/files", "POST /v1/transcriptions", "GET /v1/transcriptions/job-owned"]
        )
    }

    private func assertDeadlineCleanup(
        model: String, expectedDeletes: [String], expectedWork: [String]
    ) async throws {
        let polled = expectation(description: "Accepted job polling started")
        let unrelatedStarted = expectation(description: "Unrelated job started")
        let finished = expectation(description: "Aborted provider finished cleanup")
        Self.installResponses(polled: polled, unrelatedStarted: unrelatedStarted)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let unrelated = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            unrelated.invalidateAndCancel()
            StubURLProtocol.reset()
        }
        let recording = Task {
            try await unrelated.data(from: URL(string: "https://comparison.invalid/unrelated/job-other")!)
        }
        await fulfillment(of: [unrelatedStarted], timeout: 1)
        let registry = TranscriptionProviderRegistry(session: session, independentCleanup: true)
        let registered = await registry.provider(forModel: model)
        let provider = try XCTUnwrap(registered)
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-\(UUID()).wav")
        try Data("fixture".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let result = Task {
            await BoundedOperation.run(
                timeout: .seconds(1), onCancel: { session.invalidateAndCancel() },
                operation: {
                    defer { finished.fulfill() }
                    return try await provider.transcribeFile(
                        at: audio, apiKey: "test-owned-key", model: model, language: nil
                    )
                }
            )
        }
        await fulfillment(of: [polled], timeout: 1)
        let outcome = await result.value
        XCTAssertNil(outcome)
        await fulfillment(of: [finished], timeout: 2)
        let requests = StubURLProtocol.recordedRequests.filter { $0.url?.path != "/unrelated/job-other" }
        XCTAssertEqual(requests.filter { $0.httpMethod == "DELETE" }.compactMap(\.url?.path), expectedDeletes)
        XCTAssertEqual(requests.filter { $0.httpMethod != "DELETE" }.map {
            "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")"
        }, expectedWork, "Cancellation must not start another upload or poll")
        let otherTasks = await withCheckedContinuation { continuation in
            unrelated.getAllTasks { continuation.resume(returning: $0.filter { $0.state == .running }.count) }
        }
        XCTAssertEqual(otherTasks, 1, "Cleanup must not cancel an unrelated job")
        unrelated.invalidateAndCancel()
        _ = try? await recording.value
    }

    private nonisolated static func installResponses(
        polled: XCTestExpectation, unrelatedStarted: XCTestExpectation
    ) {
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/unrelated/job-other" {
                unrelatedStarted.fulfill()
                return .hang
            }
            if request.httpMethod == "DELETE" { return try Self.response(request, json: "{}") }
            if request.httpMethod == "GET" {
                polled.fulfill()
                return .hang
            }
            let body: String
            switch path {
            case "/v2/upload": body = #"{"audio_url":"https://api.gladia.io/file-owned"}"#
            case "/v1/files": body = #"{"id":"file-owned"}"#
            default: body = #"{"id":"job-owned"}"#
            }
            return try Self.response(request, json: body)
        }
    }

    private nonisolated static func response(_ request: URLRequest, json: String) throws -> StubURLProtocol.Outcome {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return .respond(response, Data(json.utf8))
    }
}
