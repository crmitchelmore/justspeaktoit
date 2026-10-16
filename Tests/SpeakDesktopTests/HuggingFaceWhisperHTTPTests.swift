import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakTestSupport

final class HuggingFaceWhisperHTTPTests: XCTestCase {
    private let url = URL(string: "https://huggingface.co/api/models/fixture/whisper/revision/main?blobs=true")!
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    func testMetadataUsesCredentiallessHTTPSJSONAndNoRequestBody() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return .respond(response, Data("{}".utf8))
        }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let result = try await HuggingFaceModelMetadataHTTP(session: session).metadata(at: url)
        XCTAssertEqual(result, Data("{}".utf8))
    }

    func testRedirectAndNonJSONResponsesAreRefused() async throws {
        for (code, type) in [(302, "application/json"), (200, "text/html"), (401, "application/json")] {
            StubURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: code, httpVersion: nil,
                    headerFields: ["Content-Type": type, "Location": "https://attacker.test/weights"]
                )!
                return .respond(response, Data("{}".utf8))
            }
            let session = StubURLProtocol.makeSession()
            defer { session.invalidateAndCancel() }
            do {
                _ = try await HuggingFaceModelMetadataHTTP(session: session).metadata(at: url)
                XCTFail("Untrusted response accepted")
            } catch {
                XCTAssertEqual(error as? HuggingFaceWhisperError, .invalidMetadata)
            }
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 3)
        XCTAssertTrue(StubURLProtocol.recordedRequests.allSatisfy { $0.url?.host == "huggingface.co" })
    }

    func testDeclaredAndActualOversizeMetadataUseTheSharedBound() async throws {
        let oversized = HuggingFaceWhisperDiscovery.maximumMetadataBytes + 1
        for declared in [true, false] {
            StubURLProtocol.handler = { request in
                var fields = ["Content-Type": "application/json"]
                if declared { fields["Content-Length"] = String(oversized) }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: fields
                )!
                return .respond(response, declared ? Data() : Data(repeating: 32, count: oversized))
            }
            let session = StubURLProtocol.makeSession()
            defer { session.invalidateAndCancel() }
            do {
                _ = try await HuggingFaceModelMetadataHTTP(session: session).metadata(at: url)
                XCTFail("Oversize response escaped the streaming bound")
            } catch {
                XCTAssertEqual(error as? BoundedHTTPExchange.Failure, .responseTooLarge)
            }
        }
    }

    func testUnsafeEndpointsFailBeforeRequestingAnything() async {
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        for address in ["http://huggingface.co/api/models/x/y", "https://attacker.test/api/models/x/y",
                        "https://user:password@huggingface.co/api/models/x/y",
                        "https://huggingface.co:444/api/models/x/y"] {
            do {
                _ = try await HuggingFaceModelMetadataHTTP(session: session).metadata(at: URL(string: address)!)
                XCTFail("Unsafe endpoint accepted")
            } catch {
                XCTAssertEqual(error as? HuggingFaceWhisperError, .invalidMetadata)
            }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testCancellingMetadataInterruptsTheOwnedRequest() async throws {
        let started = expectation(description: "metadata started")
        let stopped = expectation(description: "metadata cancelled")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let task = Task { try await HuggingFaceModelMetadataHTTP(session: session).metadata(at: url) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled metadata request returned a body")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }
}
