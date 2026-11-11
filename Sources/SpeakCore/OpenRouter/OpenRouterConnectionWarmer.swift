import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A bare HEAD on the same pool used by completed-request OpenRouter chat.
/// Streaming's per-request delegate sessions and native live sockets do not reuse it.
public enum OpenRouterConnectionWarmer {
    public static let timeout: TimeInterval = 5

    public static var origin: URL {
        var components = URLComponents(url: OpenRouterService.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    public static func request() -> URLRequest {
        var request = URLRequest(url: origin, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        return request
    }

    public static func warmUp(session: URLSession = .shared) async throws {
        try Task.checkCancellation()
        // Do not inherit custom default headers or cached HTTP credentials.
        let configuration = session.configuration
        guard configuration.httpAdditionalHeaders?.isEmpty != false,
              configuration.urlCredentialStorage?.allCredentials.isEmpty != false else {
            throw Failure.unsafeSession
        }
        let request = request()
        let delegate = ProbeDelegate()
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                let (_, response) = try await session.data(for: request, delegate: delegate)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse,
                      let url = http.url, BatchTranscriptionJob.isSameOrigin(url, as: origin) else {
                    throw Failure.invalidResponse
                }
                guard !(300..<400).contains(http.statusCode) else { throw Failure.redirectRefused }
                guard http.statusCode != 401, http.statusCode != 407 else { throw Failure.authenticationRefused }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw URLError(.timedOut)
            }
            _ = try await group.next()
        }
        try Task.checkCancellation()
    }

    enum Failure: Error {
        case unsafeSession, invalidResponse, redirectRefused, authenticationRefused
    }

    final class ProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            // Use Foundation's wire name without importing Apple-only trust APIs.
            // Default TLS trust evaluation is retained; HTTP/client authentication is refused.
            if challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust" {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
