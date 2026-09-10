import XCTest
@testable import SpeakCore

/// Gladia polls with the reusable account key attached, so the destination of
/// that authenticated request -- and every redirect it might follow -- has to
/// stay inside the provider's own endpoint boundary. These are also the tests
/// for cancelling a job Gladia has already accepted and started billing for.
final class GladiaBatchClientSecurityTests: XCTestCase {
    private let baseURL = URL(string: "https://gladia.test")!

    /// The polling request carries `x-gladia-key`, so a `result_url` that
    /// leaves the configured Gladia origin would hand the reusable account key
    /// to whoever supplied it. An off-origin URL is therefore never polled: the
    /// documented endpoint derived from the job id is used instead, and a
    /// response offering no usable destination is rejected outright.
    ///
    /// This test previously asserted that `https://other.test/...` was
    /// accepted, which encoded the vulnerability rather than describing correct
    /// behaviour.
    func testAnOffOriginResultURLIsNeverPolledWithTheAccountKey() async throws {
        let hostile = [
            "https://other.test/v2/transcription/abc",
            "http://gladia.test/v2/pre-recorded/abc",
            "https://gladia.test.evil.example/v2/pre-recorded/abc",
            "https://gladia.test:8443/v2/pre-recorded/abc",
            "https://user:pass@other.test/v2/pre-recorded/abc"
        ]
        for resultURL in hostile {
            let job = try GladiaBatchClient.decodeJob(
                Data(#"{"id":"abc","result_url":"\#(resultURL)"}"#.utf8), baseURL: baseURL)
            XCTAssertEqual(
                job.resultURL.absoluteString, "https://gladia.test/v2/pre-recorded/abc",
                "\(resultURL) must not be polled")
        }
        // With no job id there is nothing safe to fall back to.
        XCTAssertThrowsError(
            try GladiaBatchClient.decodeJob(
                Data(#"{"result_url":"https://other.test/v2/transcription/abc"}"#.utf8),
                baseURL: baseURL)
        ) { XCTAssertEqual($0 as? TranscriptionProviderError, .invalidResponse) }

        // End to end: a hostile job response must not produce a single request
        // to the foreign host.
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let recorder = BatchRequestRecorder()
        var client = GladiaBatchClient(baseURL: baseURL)
        client.pollInterval = 0
        client.sleep = { _ in }
        client.upload = { request, _ in
            (Data(#"{"audio_url":"https://gladia.test/file/9"}"#.utf8), Self.ok(request))
        }
        client.send = { request in
            await recorder.record(request)
            if request.httpMethod == "POST" {
                return (
                    Data(#"{"id":"abc","result_url":"https://other.test/steal"}"#.utf8),
                    Self.ok(request))
            }
            return (Data(Self.doneResult.utf8), Self.ok(request))
        }
        _ = try await client.transcribeFile(
            at: audio, apiKey: "gladia-key", model: GladiaBatchClient.catalogID, language: nil)
        let hosts = await recorder.requests.compactMap(\.url?.host)
        XCTAssertEqual(Set(hosts), ["gladia.test"])
    }

    /// A redirect is the other way an authenticated request can be walked off
    /// the provider's origin, and `x-gladia-key` is a custom header URLSession
    /// does not strip on a cross-origin hop.
    func testARedirectOffTheProviderOriginIsRefused() throws {
        let redirects = BatchTranscriptionJob.OriginBoundRedirects(origin: baseURL)
        let task = URLSession.shared.dataTask(with: baseURL)
        defer { task.cancel() }
        let response = try XCTUnwrap(
            HTTPURLResponse(url: baseURL, statusCode: 302, httpVersion: nil, headerFields: nil))

        for target in ["https://other.test/steal", "http://gladia.test/steal"] {
            let expectation = self.expectation(description: "redirect to \(target) refused")
            redirects.urlSession(
                URLSession.shared, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: target)!)
            ) { followed in
                XCTAssertNil(followed, "\(target) must not be followed")
                expectation.fulfill()
            }
            self.wait(for: [expectation], timeout: 1)
        }

        let allowed = self.expectation(description: "same-origin redirect followed")
        let onOrigin = URL(string: "https://gladia.test/v2/pre-recorded/abc")!
        redirects.urlSession(
            URLSession.shared, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: onOrigin)
        ) { followed in
            XCTAssertEqual(followed?.url, onOrigin)
            allowed.fulfill()
        }
        self.wait(for: [allowed], timeout: 1)
    }

    /// Gladia bills for a job from the moment it accepts one, so cancellation
    /// observed the instant the create response lands must still delete it --
    /// the job id must not be dropped before the cleanup handler can see it.
    func testCancellationImmediatelyAfterJobCreationStillDeletesTheJob() async throws {
        let audio = try Self.fixture(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let recorder = BatchRequestRecorder()
        let canceller = DeferredCanceller()
        var client = GladiaBatchClient(baseURL: baseURL)
        client.pollInterval = 0
        client.sleep = { _ in }
        client.upload = { request, _ in
            (Data(#"{"audio_url":"https://gladia.test/file/9"}"#.utf8), Self.ok(request))
        }
        client.send = { request in
            await recorder.record(request)
            if request.httpMethod == "POST" {
                // The create call has succeeded and the job now exists; cancel
                // the surrounding task before the id can reach anything else.
                await canceller.fire()
                return (Data(#"{"id":"abc"}"#.utf8), Self.ok(request))
            }
            if request.httpMethod == "DELETE" { return (Data(), Self.ok(request)) }
            XCTFail("polling must not start after cancellation")
            throw CancellationError()
        }

        let started = client
        let job = Task {
            try await started.transcribeFile(
                at: audio, apiKey: "key", model: GladiaBatchClient.catalogID, language: nil)
        }
        await canceller.arm { job.cancel() }
        await assertThrowsAsync(try await job.value) { XCTAssertTrue($0 is CancellationError) }

        let deletes = await recorder.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.map(\.url?.path), ["/v2/pre-recorded/abc"])
    }

    /// A polling `URLError.cancelled` is URLSession's spelling of the same
    /// cancellation, and the local polling deadline is also an abandonment;
    /// both must delete the job rather than leave it running.
    func testAURLErrorCancellationAndALocalTimeoutBothDeleteTheJob() async throws {
        for failure in [URLError(.cancelled) as Error, BatchTranscriptionJobError.timedOut] {
            let audio = try Self.fixture(extension: "wav")
            defer { try? FileManager.default.removeItem(at: audio) }
            let recorder = BatchRequestRecorder()
            var client = GladiaBatchClient(baseURL: baseURL)
            client.pollInterval = 0
            client.sleep = { _ in }
            client.upload = { request, _ in
                (Data(#"{"audio_url":"https://gladia.test/file/9"}"#.utf8), Self.ok(request))
            }
            client.send = { request in
                await recorder.record(request)
                if request.httpMethod == "POST" {
                    return (Data(#"{"id":"abc"}"#.utf8), Self.ok(request))
                }
                if request.httpMethod == "DELETE" { return (Data(), Self.ok(request)) }
                throw failure
            }
            await assertThrowsAsync(
                try await client.transcribeFile(
                    at: audio, apiKey: "key", model: GladiaBatchClient.catalogID, language: nil)
            ) { error in
                if failure is URLError {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertEqual(error as? BatchTranscriptionJobError, .timedOut)
                }
            }
            let deletes = await recorder.requests.filter { $0.httpMethod == "DELETE" }
            XCTAssertEqual(deletes.map(\.url?.path), ["/v2/pre-recorded/abc"])
        }
    }

    // MARK: - Fixtures

    private static let doneResult = """
    {"status":"done","result":{"metadata":{"audio_duration":3.25},"transcription":{
     "full_transcript":"Hello there",
     "utterances":[{"start":0.1,"end":0.6,"text":"Hello","confidence":0.95},
                   {"start":0.7,"end":1.2,"text":"there","confidence":0.85}]}}}
    """

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
