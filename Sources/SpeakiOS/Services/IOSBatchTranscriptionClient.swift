#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

struct IOSBatchTranscriptionClient {
    let apiKey: String
    let keywords: [String]
    let session: URLSession

    func transcribeFile(at url: URL, model: String, language: String?) async throws -> TranscriptionResult {
        // Credential resolution uses the trimmed ID. Use the same ID for both
        // route selection and the provider request, including file-only callers.
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch IOSBatchTranscriptionRoute.route(for: model) {
        case .appleSpeechAnalyzer:
            if #available(iOS 26.0, *) {
                return try await AppleSpeechAnalyzerTranscriber.transcribeFile(
                    at: url,
                    localeIdentifier: language,
                    engine: AppleSpeechAnalyzerEngine(modelID: model)
                )
            }
            throw AppleLocalModelError.speechTranscriberUnavailable
        case .openAI:
            return try await transcribeWithOpenAI(
                at: url,
                model: model,
                language: language,
                apiKey: try requireAPIKey()
            )
        case .cartesia:
            return try await transcribeWithCartesia(
                at: url,
                language: language,
                apiKey: try requireAPIKey()
            )
        case .metaMuse:
            return try await MetaMuseBatchClient(session: session).transcribeFile(
                at: url,
                apiKey: try requireAPIKey(),
                model: model,
                language: language,
                keywords: keywords
            )
        case .gemini:
            return try await transcribeWithGemini(
                at: url,
                model: model,
                language: language,
                apiKey: try requireAPIKey()
            )
        case .openRouter:
            return try await transcribeWithOpenRouter(
                at: url,
                model: model,
                language: language,
                apiKey: try requireAPIKey()
            )
        }
    }

    private func requireAPIKey() throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSBatchTranscriptionError.apiKeyMissing }
        return trimmed
    }

    private func transcribeWithOpenAI(
        at url: URL,
        model: String,
        language: String?,
        apiKey: String
    ) async throws -> TranscriptionResult {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let modelName = model.split(separator: "/").last.map(String.init) ?? model
        var body = Data()
        body.appendFormField(name: "model", value: modelName, boundary: boundary)
        body.appendFormField(
            name: "response_format",
            value: modelName == "gpt-4o-transcribe-diarize" ? "diarized_json" : "json",
            boundary: boundary
        )
        if modelName == "gpt-4o-transcribe-diarize" {
            body.appendFormField(name: "chunking_strategy", value: "auto", boundary: boundary)
        }
        if let languageCode = language?.split(whereSeparator: { $0 == "_" || $0 == "-" }).first {
            body.appendFormField(
                name: OpenAITranscriptionModels.batchLanguageFieldName(for: modelName),
                value: String(languageCode),
                boundary: boundary
            )
        }
        body.appendFile(
            name: "file",
            filename: url.lastPathComponent,
            mimeType: "audio/m4a",
            data: try Data(contentsOf: url),
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "OpenAI")
        let payload = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        let text = payload.transcriptText
        guard !text.isEmpty else { throw IOSBatchTranscriptionError.emptyTranscript }
        return await result(text: text, url: url, model: model, rawPayload: data)
    }

    /// Google's Interactions API, using the Google key rather than the
    /// OpenRouter one. The shared client keeps word timings and the diarised
    /// `spk_N` labels exactly as macOS does: one segment per annotated word,
    /// with the speaker attribution preserved in the raw payload.
    private func transcribeWithGemini(
        at url: URL,
        model: String,
        language: String?,
        apiKey: String
    ) async throws -> TranscriptionResult {
        do {
            return try await GeminiInteractionsClient(session: session).transcribeFile(
                at: url,
                apiKey: apiKey,
                model: model,
                language: language
            )
        } catch GeminiBatchError.missingAPIKey {
            throw IOSBatchTranscriptionError.apiKeyMissing
        } catch GeminiBatchError.emptyTranscript {
            throw IOSBatchTranscriptionError.emptyTranscript
        } catch TranscriptionProviderError.invalidResponse {
            throw IOSBatchTranscriptionError.invalidResponse
        } catch let TranscriptionProviderError.httpError(statusCode, body) {
            throw IOSBatchTranscriptionError.httpError(
                GeminiTranscribeModels.providerDisplayName, statusCode, body)
        }
    }

    /// Ink Whisper through the shared `CartesiaBatchClient`. Errors are mapped
    /// onto the same vocabulary as the sibling routes so the keyboard and the
    /// app show the provider name, and a silent recording is reported instead
    /// of inserting nothing.
    private func transcribeWithCartesia(
        at url: URL,
        language: String?,
        apiKey: String
    ) async throws -> TranscriptionResult {
        let result: TranscriptionResult
        do {
            result = try await CartesiaBatchClient(session: session).transcribeFile(
                at: url, apiKey: apiKey, language: language
            )
        } catch TranscriptionProviderError.apiKeyMissing {
            throw IOSBatchTranscriptionError.apiKeyMissing
        } catch TranscriptionProviderError.invalidResponse {
            throw IOSBatchTranscriptionError.invalidResponse
        } catch let TranscriptionProviderError.httpError(statusCode, body) {
            throw IOSBatchTranscriptionError.httpError("Cartesia", statusCode, body)
        }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IOSBatchTranscriptionError.emptyTranscript
        }
        return result
    }

    private func transcribeWithOpenRouter(
        at url: URL,
        model: String,
        language: String?,
        apiKey: String
    ) async throws -> TranscriptionResult {
        let client = OpenRouterAPIClient(apiKey: apiKey, session: session)
        do {
            return try await client.transcribeFile(at: url, model: model, language: language)
        } catch OpenRouterClientError.audioFileTooLarge {
            throw IOSBatchTranscriptionError.audioTooLarge
        } catch OpenRouterClientError.invalidResponse {
            throw IOSBatchTranscriptionError.invalidResponse
        } catch let OpenRouterClientError.httpStatus(statusCode, body) {
            throw IOSBatchTranscriptionError.httpError("OpenRouter", statusCode, body)
        }
    }

    private func validate(response: URLResponse, data: Data, service: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw IOSBatchTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw IOSBatchTranscriptionError.httpError(service, http.statusCode, body)
        }
    }

    private func result(text: String, url: URL, model: String, rawPayload: Data) async -> TranscriptionResult {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        return TranscriptionResult(
            text: text,
            segments: [.init(startTime: 0, endTime: duration, text: text)],
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: String(data: rawPayload, encoding: .utf8),
            debugInfo: nil
        )
    }
}

private struct OpenAIResponse: Decodable {
    let text: String?
    let segments: [OpenAIResponseSegment]?

    var transcriptText: String {
        guard let segments, segments.contains(where: { $0.speaker != nil }) else {
            return text ?? segments?.map(\.text).joined(separator: " ") ?? ""
        }
        return segments.map { segment in
            guard let speaker = segment.speaker else { return segment.text }
            return "\(speaker.replacingOccurrences(of: "_", with: " ").capitalized): \(segment.text)"
        }.joined(separator: "\n")
    }
}

private struct OpenAIResponseSegment: Decodable {
    let text: String
    let speaker: String?
}

private extension Data {
    mutating func appendString(_ value: String) {
        if let data = value.data(using: .utf8) { append(data) }
    }

    mutating func appendFormField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
#endif
