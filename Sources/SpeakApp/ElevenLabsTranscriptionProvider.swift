import SpeakCore
import AVFoundation
import Foundation

// MARK: - ElevenLabs Transcription Provider

/// Batch file transcription using the ElevenLabs Scribe v1 API.
///
/// Reuses the `elevenlabs.apiKey` keychain entry that TTS already stores, so users
/// who have ElevenLabs configured need no additional credential.
struct ElevenLabsTranscriptionProvider: TranscriptionProvider {
    let metadata = TranscriptionProviderMetadata(
        id: "elevenlabs",
        displayName: "ElevenLabs",
        systemImage: "waveform",
        tintColor: "orange",
        website: "https://elevenlabs.io"
    )

    private let baseURL = URL(string: "https://api.elevenlabs.io/v1")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let endpoint = baseURL.appendingPathComponent("speech-to-text")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let audioData = try Data(contentsOf: url)
        var body = Data()

        let modelID = extractModelID(from: model)
        body.appendFormField(named: "model_id", value: modelID, boundary: boundary)
        body.appendFormField(named: "timestamps_granularity", value: "word", boundary: boundary)

        if let language {
            let languageCode = extractLanguageCode(from: language)
            body.appendFormField(named: "language_code", value: languageCode, boundary: boundary)
        }

        body.appendFileField(
            named: "file",
            filename: url.lastPathComponent,
            mimeType: "audio/m4a",
            fileData: audioData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw TranscriptionProviderError.httpError(http.statusCode, responseBody)
        }

        let decoded = try JSONDecoder().decode(ElevenLabsTranscriptionResponse.self, from: data)
        return try await buildTranscriptionResult(
            response: decoded,
            audioURL: url,
            model: model,
            payload: data
        )
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "API key is empty")
        }

        let url = baseURL.appendingPathComponent("user")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(trimmed, forHTTPHeaderField: "xi-api-key")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Received a non-HTTP response", debug: debugSnapshot(request: request))
            }

            let debug = debugSnapshot(request: request, response: http, data: data)

            if (200..<300).contains(http.statusCode) {
                return .success(message: "ElevenLabs API key validated", debug: debug)
            }

            let message = "HTTP \(http.statusCode) while validating key"
            return .failure(message: message, debug: debug)
        } catch {
            return .failure(
                message: "Validation failed: \(error.localizedDescription)",
                debug: debugSnapshot(request: request, error: error)
            )
        }
    }

    func requiresAPIKey(for model: String) -> Bool {
        true
    }

    func supportedModels() -> [ModelCatalog.Option] {
        [
            ModelCatalog.Option(
                id: "elevenlabs/scribe_v1",
                displayName: "ElevenLabs Scribe v1",
                description: "ElevenLabs Scribe: high-accuracy speech-to-text with word-level timestamps.",
                estimatedLatencyMs: 800,
                latencyTier: .fast
            ),
            ModelCatalog.Option(
                id: "elevenlabs/scribe_v1_experimental",
                displayName: "ElevenLabs Scribe v1 (Experimental)",
                description: "ElevenLabs Scribe experimental model with cutting-edge accuracy improvements.",
                estimatedLatencyMs: 900,
                latencyTier: .fast
            )
        ]
    }

    // MARK: - Private Helpers

    private func extractModelID(from model: String) -> String {
        // Strip the provider prefix: "elevenlabs/scribe_v1" -> "scribe_v1"
        model.split(separator: "/").last.map(String.init) ?? model
    }

    private func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }

    private func buildTranscriptionResult(
        response: ElevenLabsTranscriptionResponse,
        audioURL: URL,
        model: String,
        payload: Data
    ) async throws -> TranscriptionResult {
        let asset = AVURLAsset(url: audioURL)
        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds

        let segments: [TranscriptionSegment]
        let wordSegments = response.words?.compactMap { word -> TranscriptionSegment? in
            guard word.type == "word" else { return nil }
            return TranscriptionSegment(
                startTime: word.start ?? 0,
                endTime: word.end ?? 0,
                text: word.text
            )
        } ?? []

        if wordSegments.isEmpty {
            segments = [TranscriptionSegment(startTime: 0, endTime: duration, text: response.text)]
        } else {
            segments = wordSegments
        }

        return TranscriptionResult(
            text: response.text,
            segments: segments,
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: String(data: payload, encoding: .utf8),
            debugInfo: nil
        )
    }

    private func debugSnapshot(
        request: URLRequest,
        response: HTTPURLResponse? = nil,
        data: Data? = nil,
        error: Error? = nil
    ) -> APIKeyValidationDebugSnapshot {
        APIKeyValidationDebugSnapshot(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            requestBody: request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            statusCode: response?.statusCode,
            responseHeaders: response.map { headers in
                headers.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
                    guard let key = entry.key as? String else { return }
                    partialResult[key] = String(describing: entry.value)
                }
            } ?? [:],
            responseBody: data.flatMap { String(data: $0, encoding: .utf8) },
            errorDescription: error?.localizedDescription
        )
    }
}

// MARK: - Response Models

private struct ElevenLabsTranscriptionResponse: Decodable {
    struct Word: Decodable {
        let text: String
        let type: String
        let start: TimeInterval?
        let end: TimeInterval?
    }

    let text: String
    let languageCode: String?
    let words: [Word]?

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
        case words
    }
}
