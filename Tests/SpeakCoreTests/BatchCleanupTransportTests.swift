import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakCore

final class BatchCleanupTransportTests: XCTestCase {
    func testPrivateSessionClosesAfterSuccess() async throws {
        try await assertPrivateSessionCloses(outcome: .success)
    }

    func testPrivateSessionClosesAfterTransportFailure() async throws {
        try await assertPrivateSessionCloses(outcome: .transportFailure)
    }

    func testPrivateSessionClosesAfterDeadline() async throws {
        try await assertPrivateSessionCloses(outcome: .deadline)
    }

    private enum Outcome { case success, transportFailure, deadline }

    private func assertPrivateSessionCloses(outcome: Outcome) async throws {
        let closed = expectation(description: "Cleanup session invalidated")
        let observer = CleanupSessionObserver(closed: closed)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let source = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        defer {
            source.invalidateAndCancel()
            StubURLProtocol.reset()
        }
        observer.ignore(source)
        let transport = BatchCleanupTransport(session: source)
        StubURLProtocol.handler = { request in
            if outcome == .deadline { return .hang }
            if outcome == .transportFailure { return .fail(URLError(.cannotConnectToHost)) }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": "0"]
            )!
            return .respond(response, Data())
        }
        var request = URLRequest(url: URL(string: "https://comparison.invalid/jobs/owned")!)
        request.httpMethod = "DELETE"
        do {
            _ = try await transport.send(request)
            XCTAssertEqual(outcome, .success)
        } catch {
            switch outcome {
            case .deadline:
                let diagnostic = error as NSError
                XCTAssertEqual(
                    error as? BoundedHTTPExchange.Failure, .timedOut,
                    "Cleanup deadline error: type=\(String(reflecting: type(of: error))) "
                        + "domain=\(diagnostic.domain) code=\(diagnostic.code)"
                )
            case .transportFailure: XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            case .success: XCTFail("Unexpected cleanup error: \(error)")
            }
        }
        await fulfillment(of: [closed], timeout: 1)
    }
}

private final class CleanupSessionObserver: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let closed: XCTestExpectation
    private var source: ObjectIdentifier?

    init(closed: XCTestExpectation) { self.closed = closed }
    func ignore(_ session: URLSession) { lock.withLock { source = ObjectIdentifier(session) } }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if lock.withLock({ source != ObjectIdentifier(session) }) { closed.fulfill() }
    }
}
