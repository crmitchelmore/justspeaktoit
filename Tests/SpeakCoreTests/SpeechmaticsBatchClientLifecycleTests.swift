import XCTest
@testable import SpeakCore

/// Once Speechmatics accepts a job it bills until the job finishes, so every
/// path that abandons one must make a best-effort delete on the way out.
final class SpeechmaticsBatchClientLifecycleTests: XCTestCase {
    private let baseURL = URL(string: "https://speechmatics.test")!

    /// Speechmatics bills for a job from the moment it accepts one, so
    /// cancellation observed the instant the create response lands must still
    /// delete it -- the job id must not be dropped before cleanup can see it.
    func testCancellationImmediatelyAfterJobCreationStillDeletesTheJob() async throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let recorder = BatchRequestRecorder()
        let canceller = DeferredCanceller()
        var client = SpeechmaticsBatchClient(baseURL: baseURL)
        client.pollInterval = 0
        client.sleep = { _ in }
        client.upload = { request, _ in
            // The job now exists remotely; cancel before the id goes anywhere.
            await canceller.fire()
            return (Data(#"{"id":"job-7"}"#.utf8), Self.ok(request))
        }
        client.send = { request in
            await recorder.record(request)
            if request.httpMethod == "DELETE" { return (Data(), Self.ok(request)) }
            XCTFail("polling must not start after cancellation")
            throw CancellationError()
        }

        let started = client
        let job = Task {
            try await started.transcribeFile(
                at: audio, apiKey: "key", model: SpeechmaticsBatchClient.standardCatalogID,
                language: nil)
        }
        await canceller.arm { job.cancel() }
        await assertThrowsAsync(try await job.value) { XCTAssertTrue($0 is CancellationError) }

        let deletes = await recorder.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.map(\.url?.path), ["/v2/jobs/job-7"])
    }

    /// A polling `URLError.cancelled` is URLSession's spelling of the same
    /// cancellation, and the local polling deadline is also an abandonment;
    /// both must delete the job rather than leave it running and billing.
    func testAURLErrorCancellationAndALocalTimeoutBothDeleteTheJob() async throws {
        for failure in [URLError(.cancelled) as Error, BatchTranscriptionJobError.timedOut] {
            let audio = try Self.fixture(extension: "wav")
            defer { try? FileManager.default.removeItem(at: audio) }
            let recorder = BatchRequestRecorder()
            var client = SpeechmaticsBatchClient(baseURL: baseURL)
            client.pollInterval = 0
            client.sleep = { _ in }
            client.upload = { request, _ in (Data(#"{"id":"job-7"}"#.utf8), Self.ok(request)) }
            client.send = { request in
                await recorder.record(request)
                if request.httpMethod == "DELETE" { return (Data(), Self.ok(request)) }
                throw failure
            }
            await assertThrowsAsync(
                try await client.transcribeFile(
                    at: audio, apiKey: "key", model: SpeechmaticsBatchClient.standardCatalogID,
                    language: nil)
            ) { error in
                if failure is URLError {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertEqual(error as? BatchTranscriptionJobError, .timedOut)
                }
            }
            let deletes = await recorder.requests.filter { $0.httpMethod == "DELETE" }
            XCTAssertEqual(deletes.map(\.url?.path), ["/v2/jobs/job-7"])
        }
    }

    // MARK: - Fixtures

    private static func fixture(extension pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(pathExtension)")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private static func ok(_ request: URLRequest) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}
