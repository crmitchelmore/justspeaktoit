import Foundation

/// Dedicated OpenRouter speech endpoints; credentials and audio/text bodies are never logged.
public actor OpenRouterAudioClient {
    public typealias APIKeyProvider = @Sendable () async -> String?
    public static let transcriptionPrefix = OpenRouterTranscriptionSelection.prefix
    private let apiKeyProvider: APIKeyProvider
    private let session: URLSession
    private let maximumInputBytes: Int
    private let maximumSpeechBytes: Int
    private let temporaryDirectory: URL

    public init(
        apiKeyProvider: @escaping APIKeyProvider,
        session: URLSession = .shared,
        maximumInputBytes: Int = 25 * 1024 * 1024,
        maximumSpeechBytes: Int = 32 * 1024 * 1024,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.maximumInputBytes = min(max(1, maximumInputBytes), 25 * 1024 * 1024)
        self.maximumSpeechBytes = min(max(1, maximumSpeechBytes), 32 * 1024 * 1024)
        self.temporaryDirectory = temporaryDirectory
    }

    public func transcribe(
        audioFileURL: URL,
        model: String,
        language: String? = nil
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        var request = try await makeRequest(path: "transcriptions", model: model)
        let payload = try transcriptionPayload(audioFileURL: audioFileURL, model: model, language: language)
        request.httpBody = try JSONEncoder().encode(payload)
        let file = try await download(request, limit: 2 * 1024 * 1024, speech: false)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(OpenRouterTranscriptionResponse.self, from: data)
        else { throw OpenRouterAudioError.invalidResponse }
        return decoded.result(model: OpenRouterTranscriptionSelection.identifier(for: model))
    }

    public func synthesize(
        text: String,
        model: String,
        voice: String?,
        speed: Double? = nil
    ) async throws -> OpenRouterSpeechResult {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 64 * 1024,
              voice.map(OpenRouterSpeechSelection.isValidVoice) ?? true,
              speed.map({ $0.isFinite && (0.25...4).contains($0) }) ?? true
        else { throw OpenRouterAudioError.invalidInput }
        var request = try await makeRequest(path: "speech", model: model)
        request.httpBody = try JSONEncoder().encode(
            OpenRouterSpeechRequest(model: model, input: text, voice: voice, speed: speed)
        )
        let file = try await download(request, limit: maximumSpeechBytes, speech: true)
        do {
            try Task.checkCancellation()
            return OpenRouterSpeechResult(audioURL: file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private func makeRequest(path: String, model: String) async throws -> URLRequest {
        guard OpenRouterSpeechSelection.isValidIdentifier(model) else {
            throw OpenRouterAudioError.invalidInput
        }
        guard let key = await apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { throw OpenRouterClientError.apiKeyMissing }
        try Task.checkCancellation()
        let url = URL(string: "https://openrouter.ai/api/v1/audio/\(path)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(OpenRouterBranding.platformDefault.title, forHTTPHeaderField: "X-Title")
        request.setValue(OpenRouterBranding.platformDefault.referer, forHTTPHeaderField: "HTTP-Referer")
        return request
    }

    private func transcriptionPayload(
        audioFileURL: URL,
        model: String,
        language: String?
    ) throws -> OpenRouterTranscriptionRequest {
        guard audioFileURL.isFileURL else { throw OpenRouterAudioError.invalidInput }
        let suffix = audioFileURL.pathExtension.lowercased()
        let format = suffix == "wave" ? "wav" : suffix
        guard ["wav", "mp3", "flac", "m4a", "ogg", "webm", "aac"].contains(format) else {
            throw OpenRouterAudioError.invalidInput
        }
        // Read at most the limit plus one byte, including if the file grows after opening.
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: audioFileURL) } catch { throw OpenRouterAudioError.invalidInput }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumInputBytes + 1), !data.isEmpty else {
            throw OpenRouterAudioError.invalidInput
        }
        guard data.count <= maximumInputBytes else {
            throw OpenRouterClientError.audioFileTooLarge(fileSize: Int64(data.count), limit: Int64(maximumInputBytes))
        }
        let languageHint = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenRouterTranscriptionRequest(
            model: model,
            inputAudio: .init(data: data.base64EncodedString(), format: format),
            language: languageHint.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private func download(_ request: URLRequest, limit: Int, speech: Bool) async throws -> URL {
        let destination = temporaryDirectory.appendingPathComponent("openrouter-\(UUID().uuidString).mp3")
        do {
            return try await OpenRouterAudioDownload.perform(
                request: request, session: session, destination: destination, limit: limit, speech: speech
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let audioError = error as? OpenRouterAudioError { throw audioError }
            if (error as? URLError)?.code == .timedOut { throw OpenRouterAudioError.timedOut }
            throw OpenRouterAudioError.transportFailure
        }
    }
}
