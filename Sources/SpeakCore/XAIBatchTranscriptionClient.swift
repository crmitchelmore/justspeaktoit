import Foundation

/// xAI's dedicated file-transcription endpoint, shared by macOS and iOS.
///
/// `POST https://api.x.ai/v1/stt` takes one multipart `file` part and returns
/// the transcript with word timings. There is no `model` field: the endpoint
/// serves one service. Inverse text normalisation (`format=true`) is only legal
/// alongside a `language`, so it is requested exactly when the user's language
/// selection resolves to one xAI documents.
///
/// Contract: https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
/// (read 2026-09-10).
public struct XAIBatchTranscriptionClient: Sendable {
    var uploadRecording: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)

    public init(session: URLSession = .shared) {
        self.uploadRecording = { request, file in
            try await session.upload(for: request, fromFile: file)
        }
    }

    public func transcribeFile(
        at url: URL,
        apiKey: String,
        language: String?,
        keywords: [String] = []
    ) async throws -> TranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
        try Task.checkCancellation()

        let upload = try Self.makeUpload(url: url, apiKey: key, language: language, keywords: keywords)
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

        guard let http = response as? HTTPURLResponse else {
            throw XAISpeechToTextError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw XAISpeechToTextError.classify(statusCode: http.statusCode, body: data)
        }
        return try Self.decode(data)
    }

    static func makeUpload(
        url: URL,
        apiKey: String,
        language: String?,
        keywords: [String]
    ) throws -> (request: URLRequest, file: URL) {
        let extensionName = url.pathExtension.lowercased()
        guard let mimeType = XAISpeechToText.containerMIMETypes[extensionName] else {
            throw XAISpeechToTextError.unsupportedAudioFormat(extensionName)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= XAISpeechToText.maximumUploadBytes else {
            throw XAISpeechToTextError.fileTooLarge
        }

        var request = URLRequest(url: XAISpeechToText.restEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // `format=true` is rejected without a language, so the two travel
        // together or not at all.
        if let code = XAISpeechToText.languageCode(for: language) {
            body.appendFormField(named: "language", value: code, boundary: boundary)
            body.appendFormField(named: "format", value: "true", boundary: boundary)
        }
        for keyterm in XAISpeechToText.boundedKeyterms(keywords) {
            body.appendFormField(named: "keyterm", value: keyterm, boundary: boundary)
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"file\"; filename=\"recording.\(extensionName)\"\r\n"
        )
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        let file = try Self.writeUpload(source: url, header: body, boundary: boundary)
        return (request, file)
    }

    /// Streams the recording into a multipart snapshot with a fixed 64 KiB
    /// buffer, so no recording-sized `Data` is retained by the request.
    private static func writeUpload(source: URL, header: Data, boundary: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
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
        struct Word: Decodable {
            let text: String
            let start: Double?
            let end: Double?
            let speaker: Int?
        }
        struct Channel: Decodable {
            let text: String?
            let words: [Word]?
        }
        struct Response: Decodable {
            let text: String?
            let duration: Double?
            let words: [Word]?
            let channels: [Channel]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw XAISpeechToTextError.invalidResponse
        }
        // A multichannel request answers per channel; a mono one answers at the
        // top level. Take whichever carries the transcript.
        let words = response.words ?? response.channels?.flatMap { $0.words ?? [] } ?? []
        let channelText = response.channels?
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let text = [response.text, channelText, words.map(\.text).joined(separator: " ")]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !text.isEmpty else { throw XAISpeechToTextError.emptyTranscript }

        let segments = words.map {
            TranscriptionSegment(startTime: $0.start ?? 0, endTime: $0.end ?? 0, text: $0.text)
        }
        let duration = response.duration ?? words.compactMap(\.end).max() ?? 0
        return TranscriptionResult(
            text: text,
            segments: segments,
            confidence: nil,
            duration: duration,
            modelIdentifier: XAISpeechToText.batchCatalogID,
            cost: Self.cost(forDuration: duration),
            rawPayload: String(data: data, encoding: .utf8),
            debugInfo: nil
        )
    }

    /// $0.10 per hour of transcribed audio; `nil` when the response carried no
    /// duration to price, rather than a guess. `inputTokens` carries the
    /// audio seconds, matching the other duration-billed providers.
    static func cost(forDuration duration: Double) -> ChatCostBreakdown? {
        guard duration > 0 else { return nil }
        return ChatCostBreakdown(
            inputTokens: Int(duration),
            outputTokens: 0,
            totalCost: Decimal(duration / 3600) * XAISpeechToText.restCostPerHourOfAudio,
            currency: "USD"
        )
    }
}
