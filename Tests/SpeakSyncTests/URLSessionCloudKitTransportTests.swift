import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest

@testable import SpeakSync

final class URLSessionCloudKitTransportTests: XCTestCase {
    private let secretURL = URL(string: "https://api.example.invalid/database/1/x?ckWebAuthToken=synthetic-secret")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testRequestIsSentAsGivenAndResponseHeadersAreCaseInsensitive() async throws {
        StubURLProtocol.handler = { request in
            .respond(
                HTTPURLResponse(
                    url: request.url ?? URL(fileURLWithPath: "/"),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Apple-CloudKit-Web-Auth-Token": "synthetic-rotated"]
                )!,
                Data(#"{"records":[]}"#.utf8)
            )
        }
        let transport = URLSessionCloudKitWebServicesTransport(session: StubURLProtocol.makeSession())
        let request = CloudKitWebServicesHTTPRequest(
            method: "POST",
            url: secretURL,
            headers: ["Content-Type": "text/plain"],
            body: Data(#"{"records":[{"recordName":"a"}]}"#.utf8)
        )

        let response = try await transport.send(request, responseLimit: 1_024)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.header("x-apple-cloudkit-web-auth-token"), "synthetic-rotated")
        XCTAssertEqual(response.body, Data(#"{"records":[]}"#.utf8))
        let sent = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "text/plain")
        XCTAssertEqual(StubURLProtocol.body(of: sent), request.body)
    }

    func testABodyOverTheLimitIsRefused() async throws {
        StubURLProtocol.handler = { request in
            .status(200, Data(repeating: 0x41, count: 4_096), url: request.url ?? URL(fileURLWithPath: "/"))
        }
        let transport = URLSessionCloudKitWebServicesTransport(session: StubURLProtocol.makeSession())
        let request = CloudKitWebServicesHTTPRequest(method: "GET", url: secretURL, headers: [:], body: nil)

        do {
            _ = try await transport.send(request, responseLimit: 1_024)
            XCTFail("Expected the limit to be enforced")
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesTransportError, .responseTooLarge(limit: 1_024))
        }
    }

    func testNetworkFailuresAreReportedByCodeWithoutTheTokenBearingURL() async throws {
        let transport = URLSessionCloudKitWebServicesTransport(session: StubURLProtocol.makeSession())
        let request = CloudKitWebServicesHTTPRequest(method: "GET", url: secretURL, headers: [:], body: nil)

        for (code, retryable) in [(URLError.Code.timedOut, true), (.notConnectedToInternet, false)] {
            StubURLProtocol.handler = { _ in .fail(URLError(code)) }
            do {
                _ = try await transport.send(request, responseLimit: 1_024)
                XCTFail("Expected \(code)")
            } catch let CloudKitWebServicesTransportError.connectionFailed(isRetryable, description) {
                XCTAssertEqual(isRetryable, retryable)
                XCTAssertEqual(description, "URLError \(code.rawValue)")
                XCTAssertFalse(description.contains("synthetic-secret"))
            }
        }
    }

    func testCancellingTheCallerCancelsTheRequest() async throws {
        StubURLProtocol.handler = { _ in .hang }
        let transport = URLSessionCloudKitWebServicesTransport(session: StubURLProtocol.makeSession())
        let request = CloudKitWebServicesHTTPRequest(method: "GET", url: secretURL, headers: [:], body: nil)

        let task = Task { try await transport.send(request, responseLimit: 1_024) }
        try await eventually { StubURLProtocol.lastRequest != nil }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
