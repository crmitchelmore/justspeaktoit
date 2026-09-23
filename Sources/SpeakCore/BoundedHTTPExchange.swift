import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One bounded HTTP exchange for shared clients outside SpeakCore.
///
/// This is the engine OpenRouter's transcription and discovery clients use: a
/// declared `Content-Length` above `limit` is refused before any byte is read,
/// the body is capped at `limit`, a wall-clock deadline bounds the exchange,
/// redirects and caching are refused, and cancelling the calling task cancels
/// the request. Apple keeps the caller's session and connection pool.
public enum BoundedHTTPExchange {
    public enum Failure: Error, Equatable, Sendable {
        case invalidResponse
        case responseTooLarge
        case timedOut
    }

    public static func perform(
        _ request: URLRequest,
        session: URLSession,
        limit: Int,
        deadline: Duration
    ) async throws -> (response: HTTPURLResponse, body: Data) {
        do {
            let result = try await OpenRouterBoundedResponseTransport.perform(
                request,
                session: session,
                limit: limit,
                deadline: deadline
            )
            return (result.http, result.body)
        } catch let failure as OpenRouterBoundedResponseTransport.Failure {
            switch failure {
            case .invalidResponse: throw Failure.invalidResponse
            case .responseTooLarge: throw Failure.responseTooLarge
            case .timedOut: throw Failure.timedOut
            }
        }
    }
}
