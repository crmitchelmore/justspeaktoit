import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Dedicated OpenRouter speech endpoints; credentials and audio/text bodies are never logged.
///
/// Transcription is Foundation-only and shared by every native host: the JSON reply is read
/// through the bounded chunk transport and decoded in memory. Speech synthesis keeps its
/// Apple-only temporary-file download in `OpenRouterAudioClient+Speech.swift`.
public actor OpenRouterAudioClient {
    public typealias APIKeyProvider = @Sendable () async -> String?
    public static let transcriptionPrefix = OpenRouterTranscriptionSelection.prefix
    /// A transcript reply larger than this is refused rather than buffered.
    static let maximumTranscriptBytes = 2 * 1024 * 1024
    /// Wall-clock bound for one audio request, in addition to the request's inactivity timeout.
    static let requestDeadline: Duration = .seconds(120)
    private let apiKeyProvider: APIKeyProvider
    let session: URLSession
    private let maximumInputBytes: Int
    let maximumSpeechBytes: Int
    let temporaryDirectory: URL

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
        try Task.checkCancellation()
        request.httpBody = try JSONEncoder().encode(payload)
        try Task.checkCancellation()
        let body = try await receiveJSON(request, limit: Self.maximumTranscriptBytes)
        try Task.checkCancellation()
        guard let decoded = try? JSONDecoder().decode(OpenRouterTranscriptionResponse.self, from: body) else {
            throw OpenRouterAudioError.invalidResponse
        }
        return decoded.result(model: OpenRouterTranscriptionSelection.identifier(for: model))
    }

    func makeRequest(path: String, model: String) async throws -> URLRequest {
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

    /// Reads a JSON reply of at most `limit` bytes. Status and content type are checked on
    /// the headers, so a provider error body is never downloaded or retained.
    private func receiveJSON(_ request: URLRequest, limit: Int) async throws -> Data {
        do {
            let response = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: limit, deadline: Self.requestDeadline
            ) { http in
                guard (200..<300).contains(http.statusCode) else {
                    // Never retain or surface provider bodies: they can contain request text or credentials.
                    throw OpenRouterAudioError.httpStatus(http.statusCode)
                }
                guard http.mimeType?.lowercased() == "application/json" else {
                    throw OpenRouterAudioError.invalidResponse
                }
            }
            guard !response.body.isEmpty else { throw OpenRouterAudioError.invalidResponse }
            return response.body
        } catch {
            throw Self.audioError(from: error)
        }
    }

    /// Maps transport outcomes onto the fixed, credential-free audio error vocabulary.
    static func audioError(from error: Error) -> Error {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return CancellationError()
        }
        if let audioError = error as? OpenRouterAudioError { return audioError }
        switch error as? OpenRouterBoundedResponseTransport.Failure {
        case .responseTooLarge: return OpenRouterAudioError.responseTooLarge
        case .timedOut: return OpenRouterAudioError.timedOut
        case .invalidResponse: return OpenRouterAudioError.invalidResponse
        case nil: break
        }
        if (error as? URLError)?.code == .timedOut { return OpenRouterAudioError.timedOut }
        return OpenRouterAudioError.transportFailure
    }
}
