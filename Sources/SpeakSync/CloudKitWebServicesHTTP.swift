import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

public struct CloudKitWebServicesHTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct CloudKitWebServicesHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    /// Header names are stored lowercased; use `header(_:)` to read them.
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public enum CloudKitWebServicesTransportError: Error, Equatable, Sendable {
    /// The body exceeded the caller's limit and was not read further.
    case responseTooLarge(limit: Int)
    case timedOut
    /// No HTTP response arrived. `retryable` marks a transient network fault.
    case connectionFailed(retryable: Bool, description: String)
    case invalidResponse
}

/// Sends one CloudKit Web Services request.
///
/// A host may supply its own implementation (for example a native WinHTTP
/// client). It must not follow redirects or use an HTTP cache, must honour
/// task cancellation promptly by throwing `CancellationError`, must stop
/// reading a body larger than `responseLimit` with `.responseTooLarge`, and
/// must never log the URL: its query carries the API and web auth tokens.
public protocol CloudKitWebServicesHTTPTransport: Sendable {
    func send(
        _ request: CloudKitWebServicesHTTPRequest,
        responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse
}

/// The portable `URLSession` transport (FoundationNetworking off Apple
/// platforms), built on SpeakCore's bounded, redirect-free exchange.
public struct URLSessionCloudKitWebServicesTransport: CloudKitWebServicesHTTPTransport {
    private let session: URLSession
    private let deadline: Duration

    public init(session: URLSession = .shared, deadline: Duration = .seconds(60)) {
        self.session = session
        self.deadline = deadline
    }

    public func send(
        _ request: CloudKitWebServicesHTTPRequest,
        responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let exchange = try await BoundedHTTPExchange.perform(
                urlRequest,
                session: session,
                limit: responseLimit,
                deadline: deadline
            )
            var headers: [String: String] = [:]
            for (key, value) in exchange.response.allHeaderFields {
                if let name = key as? String, let text = value as? String {
                    headers[name] = text
                }
            }
            return CloudKitWebServicesHTTPResponse(
                statusCode: exchange.response.statusCode,
                headers: headers,
                body: exchange.body
            )
        } catch let failure as BoundedHTTPExchange.Failure {
            switch failure {
            case .responseTooLarge: throw CloudKitWebServicesTransportError.responseTooLarge(limit: responseLimit)
            case .timedOut: throw CloudKitWebServicesTransportError.timedOut
            case .invalidResponse: throw CloudKitWebServicesTransportError.invalidResponse
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            // The description is the code only: a URLError's user info names
            // the request URL, which carries both tokens.
            throw CloudKitWebServicesTransportError.connectionFailed(
                retryable: Self.retryableCodes.contains(error.code),
                description: "URLError \(error.code.rawValue)"
            )
        }
    }

    private static let retryableCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
    ]
}
