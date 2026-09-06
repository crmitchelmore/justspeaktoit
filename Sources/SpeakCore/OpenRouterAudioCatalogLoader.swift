import Foundation

/// Bounds total request time as well as inactivity and payload size. Redirects and HTTP caching are refused.
enum OpenRouterAudioCatalogLoader {
    static func load(
        apiKey: String?, session: URLSession, timeout: Duration = .seconds(30)
    ) async throws -> [OpenRouterAudioModel] {
        try await withThrowingTaskGroup(of: [OpenRouterAudioModel].self) { group in
            group.addTask { try await stream(apiKey: apiKey, session: session) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw OpenRouterAudioCatalogError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw OpenRouterAudioCatalogError.invalidResponse }
            return result
        }
    }

    private static func stream(apiKey: String?, session: URLSession) async throws -> [OpenRouterAudioModel] {
        try Task.checkCancellation()
        let endpoint = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=speech,transcription")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: OpenRouterAudioRedirectPolicy())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw OpenRouterAudioCatalogError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenRouterAudioCatalogError.httpStatus(response.statusCode)
        }
        let limit = OpenRouterAudioCatalogSnapshot.maximumBytes
        guard response.expectedContentLength <= Int64(limit) else { throw OpenRouterAudioCatalogError.payloadTooLarge }
        return try await withTaskCancellationHandler {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw OpenRouterAudioCatalogError.payloadTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try JSONDecoder().decode(OpenRouterAudioModelResponse.self, from: data).data
        } onCancel: {
            bytes.task.cancel()
        }
    }
}
