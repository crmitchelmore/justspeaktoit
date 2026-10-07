import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bounds total request time as well as inactivity and payload size. Redirects and HTTP caching are refused.
enum OpenRouterAudioCatalogLoader {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=speech,transcription")!

    static func load(
        apiKey: String?, session: URLSession, timeout: Duration = .seconds(30)
    ) async throws -> [OpenRouterAudioModel] {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let response: OpenRouterBoundedResponseTransport.Response
        do {
            response = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: OpenRouterAudioCatalogSnapshot.maximumBytes, deadline: timeout
            ) { http in
                guard (200..<300).contains(http.statusCode) else {
                    throw OpenRouterAudioCatalogError.httpStatus(http.statusCode)
                }
            }
        } catch let failure as OpenRouterBoundedResponseTransport.Failure {
            switch failure {
            case .invalidResponse: throw OpenRouterAudioCatalogError.invalidResponse
            case .responseTooLarge: throw OpenRouterAudioCatalogError.payloadTooLarge
            case .timedOut: throw OpenRouterAudioCatalogError.timedOut
            }
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(OpenRouterAudioModelResponse.self, from: response.body).data
    }
}
