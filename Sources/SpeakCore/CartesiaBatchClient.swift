import Foundation

/// Ink Whisper is a file-transcription model; Ink-2 remains a separate live route.
/// Contract: https://docs.cartesia.ai/api-reference/stt/transcribe (2026-09-05).
public struct CartesiaBatchClient: Sendable {
    public static let catalogID = "cartesia/ink-whisper"
    public static let apiVersion = "2026-08-14"
    var uploadRecording: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)

    public init(session: URLSession = .shared) {
        self.uploadRecording = { request, file in
            try await session.upload(for: request, fromFile: file)
        }
    }

    public func transcribeFile(
        at url: URL, apiKey: String, language: String?
    ) async throws -> TranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
        try Task.checkCancellation()
        let upload = try Self.makeUpload(url: url, apiKey: key, language: language)
        defer { try? FileManager.default.removeItem(at: upload.file.deletingLastPathComponent()) }
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.uploadRecording(upload.request, upload.file)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TranscriptionProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionProviderError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decode(data)
    }

    static func makeUpload(url: URL, apiKey: String, language: String?) throws
        -> (request: URLRequest, file: URL) {
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
        let normalizedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !normalizedLanguage.isEmpty, normalizedLanguage != "automatic",
           let code = normalizedLanguage.split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            body.appendFormField(named: "language", value: String(code).lowercased(), boundary: boundary)
        }
        body.appendFormField(named: "timestamp_granularities[]", value: "word", boundary: boundary)
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"recording.\(extensionName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        let file = try Self.writeUpload(source: url, header: body, boundary: boundary)
        return (request, file)
    }

    /// Build a stable multipart snapshot with a fixed 64 KiB copy buffer.
    /// No recording-sized Data is retained in the request or upload operation.
    private static func writeUpload(source: URL, header: Data, boundary: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("upload.multipart")
        do {
            try header.write(to: file)
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            try output.seekToEnd()
            while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
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
        let duration = response.duration ?? response.words?.map(\.end).max() ?? 0
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
