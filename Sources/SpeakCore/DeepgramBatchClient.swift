import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Deepgram Transcription Provider

public struct DeepgramBatchClient: TranscriptionProvider {
    public let metadata = TranscriptionProviderMetadata(
        id: "deepgram",
        displayName: "Deepgram",
        systemImage: "waveform.circle",
        tintColor: "indigo",
        website: "https://deepgram.com"
    )

    private let baseURL = URL(string: "https://api.deepgram.com/v1")!
    private let session: URLSession

    private let durationResolver: @Sendable (URL) async throws -> TimeInterval

    public init(
        session: URLSession = .shared,
        durationResolver: @escaping @Sendable (URL) async throws -> TimeInterval = { _ in 0 }
    ) {
        self.session = session
        self.durationResolver = durationResolver
    }

    public func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let endpoint = baseURL.appendingPathComponent("listen")

        guard var urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw TranscriptionProviderError.invalidResponse
        }
        var queryItems = [
            URLQueryItem(name: "model", value: extractModelName(from: model)),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "numerals", value: "true"),
            URLQueryItem(name: "utterances", value: "true")
        ]
        if let language {
            let languageCode = language.localeLanguageCode
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }

        urlComponents.queryItems = queryItems

        guard let requestURL = urlComponents.url else {
            throw TranscriptionProviderError.invalidResponse
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let mimeType = url.pathExtension.lowercased() == "m4a"
            ? "audio/m4a" : BatchTranscriptionJob.mimeType(for: url) ?? "audio/m4a"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: url)
        request.httpBody = audioData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw TranscriptionProviderError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(DeepgramBatchResponse.self, from: data)
        return try await buildTranscriptionResult(
            response: decoded,
            audioURL: url,
            model: model,
            payload: data
        )
    }

    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        await GETProbeAPIKeyValidator(
            url: baseURL.appendingPathComponent("projects"),
            headers: { ["Authorization": "Token \($0)"] },
            serviceName: "Deepgram",
            session: session
        ).validate(key)
    }

    public func requiresAPIKey(for model: String) -> Bool {
        true
    }

    public func supportedModels() -> [ModelCatalog.Option] {
        ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
    }

    // MARK: - Private Methods

    private func extractModelName(from model: String) -> String {
        // Extract the model name after the "/" and remove any "-streaming" suffix
        var name = model.split(separator: "/").last.map(String.init) ?? model
        if name.hasSuffix("-streaming") {
            name = String(name.dropLast("-streaming".count))
        }
        return name
    }

    private func buildTranscriptionResult(
        response: DeepgramBatchResponse,
        audioURL: URL,
        model: String,
        payload: Data
    ) async throws -> TranscriptionResult {
        let duration = try await durationResolver(audioURL)

        guard let channel = response.results?.channels.first,
              let alternative = channel.alternatives.first else {
            return TranscriptionResult(
                text: "",
                segments: [],
                confidence: nil,
                duration: duration,
                modelIdentifier: model,
                cost: nil,
                rawPayload: String(data: payload, encoding: .utf8),
                debugInfo: nil
            )
        }

        let text = alternative.transcript
        let segments: [TranscriptionSegment]

        if let words = alternative.words, !words.isEmpty {
            segments = words.map { word in
                TranscriptionSegment(
                    startTime: word.start,
                    endTime: word.end,
                    text: word.word
                )
            }
        } else {
            segments = [TranscriptionSegment(startTime: 0, endTime: duration, text: text)]
        }

        return TranscriptionResult(
            text: text,
            segments: segments,
            confidence: alternative.confidence,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: String(data: payload, encoding: .utf8),
            debugInfo: nil
        )
    }

}

// MARK: - Response Models

private struct DeepgramBatchResponse: Decodable {
    let results: DeepgramBatchResults?
}

private struct DeepgramBatchResults: Decodable {
    let channels: [DeepgramBatchChannel]
}

private struct DeepgramBatchChannel: Decodable {
    let alternatives: [DeepgramBatchAlternative]
}

private struct DeepgramBatchAlternative: Decodable {
    let transcript: String
    let confidence: Double?
    let words: [DeepgramBatchWord]?
}

private struct DeepgramBatchWord: Decodable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
}
