import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// Lifecycle and bounds of the shared chunk-streaming transport, independent of any caller.
final class OpenRouterBoundedResponseTransportTests: XCTestCase {
    private var session: URLSession!
    private let endpoint = URL(string: "https://stub.invalid/bounded")!

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDeliversHeadersAndBodyUpToTheLimitInclusiveWithoutFollowingRedirects() async throws {
        StubURLProtocol.handler = { request in
            .respond(Self.response(request, headers: ["X-Probe": "kept"]), Data(repeating: 7, count: 8))
        }
        let response = try await perform(limit: 8)
        XCTAssertEqual(response.http.statusCode, 200)
        XCTAssertEqual(response.http.value(forHTTPHeaderField: "X-Probe"), "kept")
        XCTAssertEqual(response.body, Data(repeating: 7, count: 8))

        StubURLProtocol.handler = { request in
            .respond(Self.response(request, status: 302, headers: ["Location": "https://elsewhere.invalid/"]), Data())
        }
        let redirect = try await perform(limit: 8)
        XCTAssertEqual(redirect.http.statusCode, 302)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
    }

    func testDeclaredContentLengthAboveTheLimitIsRefusedBeforeTheBody() async throws {
        let stopped = expectation(description: "Request cancelled")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(Self.response(request, headers: ["Content-Length": "9"]), Data())
        }
        await assertFailure(.responseTooLarge, limit: 8, deadline: .seconds(5))
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testStreamedBytesAboveTheLimitCancelTheTask() async throws {
        let stopped = expectation(description: "Request cancelled")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(Self.response(request), Data(repeating: 1, count: 9))
        }
        await assertFailure(.responseTooLarge, limit: 8, deadline: .seconds(5))
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testDeadlineCancelsARequestThatNeverFinishes() async throws {
        let hung = expectation(description: "Hanging request cancelled")
        StubURLProtocol.onStopLoading = { hung.fulfill() }
        StubURLProtocol.handler = { _ in .hang }
        await assertFailure(.timedOut, limit: 8, deadline: .milliseconds(200))
        await fulfillment(of: [hung], timeout: 5)

        let partial = expectation(description: "Partial body cancelled")
        StubURLProtocol.onStopLoading = { partial.fulfill() }
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(Self.response(request), Data(repeating: 1, count: 4))
        }
        await assertFailure(.timedOut, limit: 8, deadline: .milliseconds(200))
        await fulfillment(of: [partial], timeout: 5)
    }

    func testHeaderPolicyRejectionSurfacesWithoutReadingTheBody() async throws {
        let stopped = expectation(description: "Rejected request cancelled")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(Self.response(request, status: 503), Data("never read".utf8))
        }
        do {
            _ = try await OpenRouterBoundedResponseTransport.perform(
                URLRequest(url: endpoint), session: session, limit: 8, deadline: .seconds(5)
            ) { http in
                guard http.statusCode == 200 else { throw Rejected(status: http.statusCode) }
            }
            XCTFail("Expected the header policy to reject")
        } catch {
            XCTAssertEqual(error as? Rejected, Rejected(status: 503))
        }
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testNonHTTPResponseIsInvalid() async {
        StubURLProtocol.handler = { request in
            let plain = URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            return .respond(plain, Data())
        }
        await assertFailure(.invalidResponse, limit: 8, deadline: .seconds(5))
    }

    func testTaskCancellationCancelsTheTransportAndResolvesExactlyOnce() async throws {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request cancelled")
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { _ in .hang }
        let task = Task { try await self.perform(limit: 8, deadline: .seconds(30)) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await fulfillment(of: [stopped], timeout: 5)
        // A late completion from the cancelled task must find nothing left to resume.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testPreCancelledTaskNeverStartsARequest() async {
        StubURLProtocol.handler = { _ in .hang }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.perform(limit: 8, deadline: .seconds(30))
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    // MARK: - Helpers

    private struct Rejected: Error, Equatable {
        let status: Int
    }

    /// Every stubbed reply declares a content type. URLSession holds back an untyped response
    /// for MIME sniffing until enough body bytes or the end of the load arrive, which would
    /// turn these header-time contracts into deadline waits.
    private static func response(
        _ request: URLRequest, status: Int = 200, headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        let fields = headers.merging(["Content-Type": "application/octet-stream"]) { explicit, _ in explicit }
        return HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: fields)!
    }

    private func perform(limit: Int, deadline: Duration = .seconds(5)) async throws
        -> OpenRouterBoundedResponseTransport.Response {
        try await OpenRouterBoundedResponseTransport.perform(
            URLRequest(url: endpoint), session: session, limit: limit, deadline: deadline
        )
    }

    private func assertFailure(
        _ expected: OpenRouterBoundedResponseTransport.Failure, limit: Int, deadline: Duration
    ) async {
        do {
            _ = try await perform(limit: limit, deadline: deadline)
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? OpenRouterBoundedResponseTransport.Failure, expected, "\(error)")
        }
    }
}
