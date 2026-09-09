import Foundation

public struct AzureBatchTranscriptionClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func transcribeFile(
        at url: URL, credentials: String, endpoint: String, model: String, language: String?,
        keywords: [String] = []
    ) async throws -> TranscriptionResult {
        guard AzureTranscriptionModels.batchIDs.contains(model)
        else { throw AzureSpeechError.unsupportedModel }
        let config = try AzureSpeechConfiguration(credentials: credentials)
        let origin = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.transcriptionURL : try AzureSpeechConfiguration.resourceURL(endpoint)
        try Task.checkCancellation()
        let audio = try await MetaMuseAudioPreparer.prepareWAV(at: url)
        guard audio.data.count > 44 else { throw AzureSpeechError.emptyInput }
        guard audio.data.count < 300_000_000 else {
            throw AzureSpeechError.configuration("Azure accepts audio files smaller than 300 MB.")
        }
        let request = try Self.request(
            origin: origin, key: config.apiKey, audio: audio.data, model: model, language: language,
            keywords: keywords
        )
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AzureSpeechError.invalidResponse }
        guard http.statusCode == 200 else { throw AzureSpeechError.service(http.statusCode) }
        return try Self.result(data: data, model: model)
    }

    // One explicit contract parameter per multipart request input.
    // swiftlint:disable:next function_parameter_count
    static func request(
        origin: URL, key: String, audio: Data, model: String, language: String?, keywords: [String]
    ) throws -> URLRequest {
        guard AzureTranscriptionModels.batchIDs.contains(model)
        else { throw AzureSpeechError.unsupportedModel }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = "/speechtotext/transcriptions:transcribe"
        components.queryItems = [.init(name: "api-version", value: "2025-10-15")]
        var definition: [String: Any] = [:]
        if model != AzureTranscriptionModels.fast {
            definition["enhancedMode"] = [
                "enabled": true,
                "model": model == AzureTranscriptionModels.mai2 ? "MAI-Transcribe-2" : "MAI-Transcribe-1.5"
            ] as [String: Any]
        }
        if let language, language != "auto", language != "automatic", !language.isEmpty {
            definition["locales"] = [language.replacingOccurrences(of: "_", with: "-")]
        }
        if !keywords.isEmpty { definition["phraseList"] = ["phrases": Array(keywords.prefix(100))] }
        let boundary = "Azure-\(UUID().uuidString)"
        var body = Data()
        body.appendAzurePart(name: "definition", contentType: "application/json",
                             data: try JSONSerialization.data(withJSONObject: definition), boundary: boundary)
        body.appendAzurePart(name: "audio", filename: "recording.wav", contentType: "audio/wav",
                             data: audio, boundary: boundary)
        body.append(Data("--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: components.url!, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func result(data: Data, model: String) throws -> TranscriptionResult {
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard result.combinedPhrases != nil || result.phrases != nil
        else { throw AzureSpeechError.invalidResponse }
        let phrases = result.phrases ?? []
        let text = result.combinedPhrases?.map(\.text).joined(separator: " ")
            ?? phrases.map(\.text).joined(separator: " ")
        return TranscriptionResult(
            text: text,
            segments: phrases.map {
                TranscriptionSegment(startTime: ($0.offsetMilliseconds ?? 0) / 1_000,
                                     endTime: (
                                         ($0.offsetMilliseconds ?? 0) + ($0.durationMilliseconds ?? 0)
                                     ) /
                                         1_000,
                                     text: $0.text)
            },
            confidence: nil, duration: (result.durationMilliseconds ?? 0) / 1_000,
            modelIdentifier: model, cost: nil, rawPayload: String(data: data, encoding: .utf8), debugInfo: nil
        )
    }

    private struct Response: Decodable {
        let durationMilliseconds: Double?
        let combinedPhrases: [Phrase]?
        let phrases: [Phrase]?
    }
    private struct Phrase: Decodable {
        let text: String
        let offsetMilliseconds: Double?
        let durationMilliseconds: Double?
    }
}

private extension Data {
    mutating func appendAzurePart(
        name: String,
        filename: String? = nil,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        var header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\""
        if let filename { header += "; filename=\"\(filename)\"" }
        header += "\r\nContent-Type: \(contentType)\r\n\r\n"
        append(Data(header.utf8)); append(data); append(Data("\r\n".utf8))
    }
}
