import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Snapshots configuration before the work session is invalidated, then creates
/// a short-lived transport only when an accepted job needs deletion.
final class BatchCleanupTransport: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let delegate: (any URLSessionDelegate)?
    private let queue: OperationQueue

    init(session: URLSession) {
        configuration = session.configuration
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        delegate = session.delegate
        queue = session.delegateQueue
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard request.httpMethod == "DELETE" else { throw URLError(.unsupportedURL) }
        let owned = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { owned.invalidateAndCancel() }
        let response = try await BoundedHTTPExchange.perform(
            request, session: owned, limit: 64 * 1_024, deadline: .seconds(10)
        )
        return (response.body, response.response)
    }
}
