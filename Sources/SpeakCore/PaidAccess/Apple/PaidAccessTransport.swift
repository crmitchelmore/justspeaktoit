import Foundation

/// Request plumbing for ``PaidAccessHTTPClient``: every request gets the
/// explicit timeout and a correlation identifier, credentials only ever go in
/// headers, and a paid settlement whose outcome cannot be confirmed reports an
/// unknown outcome instead of a retryable failure.
struct PaidAccessTransport: Sendable {
    let baseURL: URL
    let session: URLSession
    let timeout: TimeInterval

    func makeRequest(
        path: String,
        method: String,
        session sessionToken: PaidAccessSession?,
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw PaidAccessError.invalidResponse
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw PaidAccessError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: self.timeout)
        request.httpMethod = method
        request.setValue(PaidAccessHTTPClient.newCorrelationID(), forHTTPHeaderField: "X-Correlation-ID")
        if let sessionToken {
            request.setValue("Bearer \(sessionToken.accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func send<Response: Decodable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        let data = try await self.sendExpectingData(request)
        do {
            return try JSONDecoder.paidAccess.decode(Response.self, from: data)
        } catch {
            throw Self.submissionUncertainty(request) ?? PaidAccessError.invalidResponse
        }
    }

    private static func submissionUncertainty(_ request: URLRequest) -> PaidAccessError? {
        guard request.value(forHTTPHeaderField: "X-Paid-Settlement-Contract") == "1",
              let key = request.value(forHTTPHeaderField: "Idempotency-Key") else { return nil }
        return .operationOutcome(.unknown, idempotencyKey: key,
                                 correlationID: request.value(forHTTPHeaderField: "X-Correlation-ID"))
    }

    func sendExpectingData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw Self.submissionUncertainty(request) ?? PaidAccessError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Self.submissionUncertainty(request) ?? PaidAccessError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PaidAccessHTTPClient.error(
                forStatus: http.statusCode, body: data,
                submittedOperation: Self.submissionUncertainty(request) == nil ? nil
                    : request.value(forHTTPHeaderField: "Idempotency-Key"),
                correlationID: request.value(forHTTPHeaderField: "X-Correlation-ID")
            )
        }
        return data
    }

    func encodeBody(_ value: [String: Any], into request: inout URLRequest) throws {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: value)
        } catch {
            throw PaidAccessError.invalidResponse
        }
    }
}
