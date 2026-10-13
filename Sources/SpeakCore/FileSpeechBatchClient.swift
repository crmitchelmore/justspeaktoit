import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Published contracts checked 2026-10-13; see Docs/batch-transcription-providers.md.
public struct FileSpeechBatchClient: TranscriptionProvider {
    public let provider: FileSpeechProvider
    public var metadata: TranscriptionProviderMetadata { provider.metadata }
    private let session: URLSession
    private let durationResolver: @Sendable (URL) async throws -> TimeInterval
    static let maximumAudioBytes = 25 * 1_024 * 1_024

    public init(
        provider: FileSpeechProvider, session: URLSession = .shared,
        durationResolver: @escaping @Sendable (URL) async throws -> TimeInterval = { _ in 0 }
    ) {
        self.provider = provider
        self.session = session
        self.durationResolver = durationResolver
    }

    public func supportedModels() -> [ModelCatalog.Option] {
        [provider.option] + (provider == .reson8 ? [FileSpeechProvider.reson8LiveOption] : [])
    }

    public func requiresAPIKey(for model: String) -> Bool { true }

    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(message: "API key is empty.")
        }
        // No documented free entitlement probe for these STT APIs. Do not
        // upload audio just to validate a credential or claim it was verified.
        return .success(message: "Key saved; \(metadata.displayName) access is checked when transcribing.")
    }

    public func transcribeFile(
        at url: URL, apiKey: String, model: String, language: String?
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
        guard model.trimmingCharacters(in: .whitespacesAndNewlines) == provider.modelID else {
            throw FileSpeechError.unsupportedModel(model)
        }
        let request = try makeRequest(audioURL: url, apiKey: key, language: language)
        let response: HTTPURLResponse
        let body: Data
        do {
            (response, body) = try await BoundedHTTPExchange.perform(
                request, session: session, limit: 8 * 1_024 * 1_024, deadline: .seconds(120)
            )
        } catch {
            throw BatchTranscriptionJob.mapCancellation(error)
        }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw TranscriptionProviderError.httpError(
                response.statusCode, String(data: body, encoding: .utf8) ?? "<non-text response>"
            )
        }
        let duration = try await durationResolver(url)
        try Task.checkCancellation()
        switch provider {
        case .smallest: return try decodePulse(body, captureDuration: duration)
        case .reson8: return try decodeReson8(body, captureDuration: duration)
        case .stepfun:
            guard response.mimeType?.lowercased() == "text/event-stream" else {
                throw TranscriptionProviderError.invalidResponse
            }
            return try StepAudio3Response.decode(body, captureDuration: duration)
        }
    }

    func makeRequest(audioURL: URL, apiKey: String, language: String?) throws -> URLRequest {
        let format = audioURL.pathExtension.lowercased()
        let formats = provider == .stepfun
            ? ["ogg", "mp3", "wav", "m4a"] : ["wav", "mp3", "flac", "ogg", "opus", "m4a", "webm"]
        guard formats.contains(format) else { throw FileSpeechError.unsupportedFormat(format) }
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        guard let size = attributes[.size] as? NSNumber else { throw TranscriptionProviderError.invalidResponse }
        guard size.int64Value <= Self.maximumAudioBytes else { throw FileSpeechError.fileTooLarge }
        try Task.checkCancellation()
        let audio = try Data(contentsOf: audioURL, options: .mappedIfSafe)
        guard audio.count <= Self.maximumAudioBytes else { throw FileSpeechError.fileTooLarge }
        let (endpoint, body) = try makePayload(audio: audio, format: format, language: language)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(
            provider == .reson8 ? "ApiKey \(apiKey)" : "Bearer \(apiKey)", forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            provider == .stepfun ? "application/json" : "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(provider == .stepfun ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private func makePayload(audio: Data, format: String, language: String?) throws -> (URL, Data) {
        let code = FileSpeechProvider.languageCode(language)
        var components: URLComponents
        var body = audio
        switch provider {
        case .smallest:
            guard code == nil || code == "en" else {
                throw FileSpeechError.unsupportedLanguage("Pulse Pro", code ?? "")
            }
            components = URLComponents(string: "https://api.smallest.ai/waves/v1/stt/")!
            components.queryItems = [
                URLQueryItem(name: "model", value: "pulse-pro"),
                URLQueryItem(name: "language", value: "en"),
                URLQueryItem(name: "word_timestamps", value: "true")
            ]
        case .reson8:
            components = URLComponents(string: "https://api.reson8.dev/v1/speech-to-text/prerecorded")!
            components.queryItems = [
                URLQueryItem(name: "include_timestamps", value: "true"),
                URLQueryItem(name: "include_words", value: "true"),
                URLQueryItem(name: "include_confidence", value: "true")
            ]
            if let hint = try FileSpeechProvider.reson8Language(language) {
                components.queryItems?.append(URLQueryItem(name: "language", value: hint))
            }
            if format == "m4a" { components.queryItems?.append(URLQueryItem(name: "encoding", value: "m4a")) }
        case .stepfun:
            components = URLComponents(string: "https://api.stepfun.com/v1/audio/asr/sse")!
            var transcription: [String: Any] = [
                "model": "stepaudio-3-asr-max", "enable_itn": true, "enable_timestamp": true
            ]
            if let code { transcription["language"] = code }
            body = try JSONSerialization.data(withJSONObject: [
                "audio": [
                    "data": audio.base64EncodedString(),
                    "input": ["transcription": transcription, "format": ["type": format]]
                ]
            ])
        }
        guard let endpoint = components.url else { throw TranscriptionProviderError.invalidResponse }
        return (endpoint, body)
    }

    private func decodePulse(_ data: Data, captureDuration: TimeInterval) throws -> TranscriptionResult {
        struct Word: Decodable {
            let word: String
            let start: Double
            let end: Double
            let confidence: Double?
        }
        struct Metadata: Decodable { let duration: Double? }
        struct Response: Decodable {
            let status: String
            let transcription: String?
            let words: [Word]?
            let metadata: Metadata?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.status == "success", let text = response.transcription else {
            throw TranscriptionProviderError.invalidResponse
        }
        let words = response.words ?? []
        let duration = response.metadata?.duration ?? captureDuration
        let confidence = words.compactMap(\.confidence)
        return try result(
            text: text,
            segments: words.map { TranscriptionSegment(startTime: $0.start, endTime: $0.end, text: $0.word) },
            duration: duration,
            confidence: confidence.isEmpty ? nil : confidence.reduce(0, +) / Double(confidence.count),
            data: data, costPerHour: Decimal(string: "0.24"), currency: "USD"
        )
    }

    private func decodeReson8(_ data: Data, captureDuration: TimeInterval) throws -> TranscriptionResult {
        struct Word: Decodable {
            let text: String
            let startMs: Double?
            let durationMs: Double?
            let confidence: Double?
        }
        struct Response: Decodable {
            let text: String
            let durationMs: Double?
            let words: [Word]?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        let words = response.words ?? []
        return try result(
            text: response.text,
            segments: words.map {
                let start = ($0.startMs ?? 0) / 1_000
                return TranscriptionSegment(
                    startTime: start, endTime: start + ($0.durationMs ?? 0) / 1_000, text: $0.text
                )
            },
            duration: response.durationMs.map { $0 / 1_000 } ?? captureDuration, data: data
        )
    }

    private func result(
        text: String, segments: [TranscriptionSegment], duration: TimeInterval,
        confidence: Double? = nil, data: Data, costPerHour: Decimal? = nil, currency: String = "USD"
    ) throws -> TranscriptionResult {
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else {
            throw TranscriptionProviderError.invalidResponse
        }
        let cost = costPerHour.flatMap { rate -> ChatCostBreakdown? in
            guard duration > 0 else { return nil }
            return ChatCostBreakdown(
                inputTokens: Int(duration), outputTokens: 0,
                totalCost: Decimal(duration) * rate / 3_600, currency: currency
            )
        }
        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), segments: segments,
            confidence: confidence, duration: duration, modelIdentifier: provider.modelID,
            cost: cost, rawPayload: String(data: data, encoding: .utf8), debugInfo: nil
        )
    }
}
