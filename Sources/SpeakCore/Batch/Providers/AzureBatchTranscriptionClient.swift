import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AzureBatchTranscriptionClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func transcribeFile(
        at url: URL, credentials: String, endpoint: String, model: String, language: String?,
        keywords: [String] = []
    ) async throws -> TranscriptionResult {
        guard AzureTranscriptionModels.batchIDs.contains(model)
        else { throw AzureSpeechError.unsupportedModel }
        let connection = try AzureSpeechConfiguration.batchConnection(credentials: credentials, endpoint: endpoint)
        let origin = connection.origin
        try Task.checkCancellation()
        let audio = try await MetaMuseAudioPreparer.prepareWAV(at: url)
        guard audio.data.count > 44 else { throw AzureSpeechError.emptyInput }
        guard audio.data.count < 300_000_000 else {
            throw AzureSpeechError.configuration("Azure accepts audio files smaller than 300 MB.")
        }
        let request = try Self.request(
            origin: origin, key: connection.apiKey, audio: audio.data, model: model, language: language,
            keywords: keywords
        )
        // `Ocp-Apim-Subscription-Key` is a custom header URLSession does not
        // strip on a cross-origin hop, and the body is the user's recording.
        let redirects = BatchTranscriptionJob.OriginBoundRedirects(origin: origin)
        let (data, response) = try await session.data(for: request, delegate: redirects)
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
        let definitionData = try JSONSerialization.data(withJSONObject: definition)
        let definitionHeader = Data.azurePartHeader(
            name: "definition", contentType: "application/json", boundary: boundary
        )
        let audioHeader = Data.azurePartHeader(
            name: "audio", filename: "recording.wav", contentType: "audio/wav", boundary: boundary
        )
        let end = Data("--\(boundary)--\r\n".utf8)
        if origin.scheme == "http" {
            guard definitionData.count <= 64 * 1024,
                  audio.count + definitionData.count + definitionHeader.count
                  + audioHeader.count + end.count + 4 <= 32 * 1024 * 1024 else {
                throw AzureSpeechError.configuration(
                    "The local Azure proxy accepts multipart recordings up to 32 MiB."
                )
            }
        }
        var body = Data()
        body.append(definitionHeader)
        body.append(definitionData)
        body.append(Data("\r\n".utf8))
        body.append(audioHeader)
        body.append(audio)
        body.append(Data("\r\n".utf8))
        body.append(end)
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
    static func azurePartHeader(
        name: String,
        filename: String? = nil,
        contentType: String,
        boundary: String
    ) -> Data {
        var header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\""
        if let filename { header += "; filename=\"\(filename)\"" }
        header += "\r\nContent-Type: \(contentType)\r\n\r\n"
        return Data(header.utf8)
    }
}
