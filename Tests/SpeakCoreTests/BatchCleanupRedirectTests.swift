#if canImport(Network)
import Foundation
import Network
import XCTest

@testable import SpeakCore

final class BatchCleanupRedirectTests: XCTestCase {
    func testCleanupRefusesCrossOriginRedirectsWithProviderCredentials() async throws {
        let ready = expectation(description: "Loopback listener ready")
        let server = try CleanupRedirectServer(ready: ready)
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 2)
        let port = try XCTUnwrap(server.port)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = BatchCleanupTransport(session: session)
        for header in ["x-gladia-key", "Authorization"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/jobs/owned")!)
            request.httpMethod = "DELETE"
            request.setValue("synthetic-owned-key", forHTTPHeaderField: header)
            let (_, response) = try await transport.send(request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
        }
        let requests = server.requests
        guard requests.count == 2 else {
            XCTFail("Neither cleanup may follow its redirect: saw \(requests.count) requests")
            return
        }
        XCTAssertTrue(requests.allSatisfy { $0.hasPrefix("DELETE /jobs/owned HTTP/") })
        XCTAssertTrue(requests[0].lowercased().contains("x-gladia-key: synthetic-owned-key"))
        XCTAssertTrue(requests[1].lowercased().contains("authorization: synthetic-owned-key"))
    }
}

/// Uses a real HTTP hop: URLProtocol mocks do not reliably exercise Foundation redirects.
private final class CleanupRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "comparison.cleanup.redirect-test")
    private let lock = NSLock()
    private var received: [String] = []
    private var connections: [NWConnection] = []
    var port: UInt16? { listener.port?.rawValue }
    var requests: [String] { lock.withLock { received } }

    init(ready: XCTestExpectation) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        let active = lock.withLock { connections }
        for connection in active { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, previous: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous
            bytes.append(data ?? Data())
            guard let request = String(data: bytes, encoding: .utf8) else { connection.cancel(); return }
            guard request.contains("\r\n\r\n") else {
                if !done, error == nil, bytes.count < 65_536 {
                    self.receive(connection, previous: bytes)
                } else { connection.cancel() }
                return
            }
            self.lock.withLock { self.received.append(request) }
            // A different host is a different origin, even though both resolve to loopback.
            let response = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://localhost:\(self.port ?? 0)/stolen"
                + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
