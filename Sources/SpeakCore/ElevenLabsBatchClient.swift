import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - ElevenLabs Transcription Provider

/// Batch file transcription using the ElevenLabs Scribe v2 API.
///
/// Reuses the `elevenlabs.apiKey` keychain entry that TTS already stores, so users
/// who have ElevenLabs configured need no additional credential.
public struct ElevenLabsBatchClient: TranscriptionProvider {
    public let metadata = TranscriptionProviderMetadata(
        id: "elevenlabs",
        displayName: "ElevenLabs",
        systemImage: "waveform",
        tintColor: "orange",
        website: "https://elevenlabs.io"
    )

    private let baseURL = URL(string: "https://api.elevenlabs.io/v1")!
    private let session: URLSession
    private let staging: SharedMultipartUploadStaging?

    private let durationResolver: @Sendable (URL) async throws -> TimeInterval

    public init(
        session: URLSession = .shared,
        staging: SharedMultipartUploadStaging? = nil,
        durationResolver: @escaping @Sendable (URL) async throws -> TimeInterval = { _ in 0 }
    ) {
        self.session = session
        self.staging = staging
        self.durationResolver = durationResolver
    }

    public func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let endpoint = baseURL.appendingPathComponent("speech-to-text")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        var fields = [
            OpenAICompatibleBatchTranscriptionClient.FormField(name: "model_id", value: extractModelID(from: model)),
            .init(name: "timestamps_granularity", value: "word")
        ]
        if let language { fields.append(.init(name: "language_code", value: language.localeLanguageCode)) }
        let mimeType = url.pathExtension.lowercased() == "m4a"
            ? "audio/m4a" : BatchTranscriptionJob.mimeType(for: url) ?? "audio/m4a"
        let (data, _) = try await OpenAICompatibleBatchTranscriptionClient(
            session: session, sharedStaging: try BatchUploadStaging.resolve(staging)
        ).upload(
            request: request, fields: fields,
            file: .init(fieldName: "file", filename: url.lastPathComponent, mimeType: mimeType, sourceURL: url),
            providerID: metadata.id
        )

        let decoded = try JSONDecoder().decode(ElevenLabsTranscriptionResponse.self, from: data)
        return try await buildTranscriptionResult(
            response: decoded,
            audioURL: url,
            model: model,
            payload: data
        )
    }

    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        await ElevenLabsSTTAPIKeyValidator(session: session).validate(key)
    }

    public func requiresAPIKey(for model: String) -> Bool {
        true
    }

    public func supportedModels() -> [ModelCatalog.Option] {
        ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
    }

    // MARK: - Private Helpers

    private func extractModelID(from model: String) -> String {
        // Strip the provider prefix: "elevenlabs/scribe_v2" -> "scribe_v2"
        model.split(separator: "/").last.map(String.init) ?? model
    }

    private func buildTranscriptionResult(
        response: ElevenLabsTranscriptionResponse,
        audioURL: URL,
        model: String,
        payload: Data
    ) async throws -> TranscriptionResult {
        let duration = try await durationResolver(audioURL)

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
