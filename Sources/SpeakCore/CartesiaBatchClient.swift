import Foundation

/// Ink Whisper is a file-transcription model; Ink-2 remains a separate live route.
/// Contract: https://docs.cartesia.ai/api-reference/stt/transcribe (2026-09-05).
public struct CartesiaBatchClient: Sendable {
    public static let catalogID = "cartesia/ink-whisper"
    public static let apiVersion = "2026-08-14"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func transcribeFile(
        at url: URL, apiKey: String, language: String?
    ) async throws -> TranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
        try Task.checkCancellation()
        let request = try Self.makeRequest(url: url, apiKey: key, language: language)
        let (data, response) = try await self.session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TranscriptionProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionProviderError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decode(data)
    }

    static func makeRequest(url: URL, apiKey: String, language: String?) throws -> URLRequest {
        let mimeTypes = [
            "flac": "audio/flac", "m4a": "audio/mp4", "mp3": "audio/mpeg", "mp4": "audio/mp4",
            "mpeg": "audio/mpeg", "mpga": "audio/mpeg", "oga": "audio/ogg", "ogg": "audio/ogg",
            "wav": "audio/wav", "webm": "audio/webm"
        ]
        let extensionName = url.pathExtension.lowercased()
        guard let mimeType = mimeTypes[extensionName] else {
            throw InputError.unsupportedAudioFormat
        }
        var request = URLRequest(url: URL(string: "https://api.cartesia.ai/stt")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.appendFormField(named: "model", value: "ink-whisper", boundary: boundary)
        // The documented API default is English; no auto-detection value is advertised.
        if let language, language != "automatic",
           let code = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            body.appendFormField(named: "language", value: String(code).lowercased(), boundary: boundary)
        }
        body.appendFormField(named: "timestamp_granularities[]", value: "word", boundary: boundary)
        body.appendFileField(named: "file", filename: "recording.\(extensionName)", mimeType: mimeType,
                             fileData: try Data(contentsOf: url), boundary: boundary)
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    static func decode(_ data: Data) throws -> TranscriptionResult {
        struct Response: Decodable {
            let type: String
            let text: String
            let duration: Double?
            let words: [Word]?
            struct Word: Decodable {
                let word: String
                let start: Double
                let end: Double
            }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.type == "transcript" else { throw TranscriptionProviderError.invalidResponse }
        let duration = response.duration ?? 0
        let segments = response.words?.map {
            TranscriptionSegment(startTime: $0.start, endTime: $0.end, text: $0.word)
        } ?? []
        return TranscriptionResult(text: response.text, segments: segments, confidence: nil,
                                   duration: duration, modelIdentifier: Self.catalogID, cost: nil,
                                   rawPayload: String(data: data, encoding: .utf8), debugInfo: nil)
    }

    private enum InputError: LocalizedError {
        case unsupportedAudioFormat
        var errorDescription: String? {
            "Ink Whisper needs a WAV, M4A, MP3, MP4, MPEG, Ogg, FLAC, or WebM recording."
        }
    }
}
