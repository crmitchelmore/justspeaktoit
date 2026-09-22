import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transcription through OpenRouter's chat completions for the catalogue's audio-capable
/// chat models. The recording travels inline as base64 `input_audio` after a text prompt,
/// and the first non-empty choice is the transcript.
///
/// This is the whole wire contract, Foundation-only, so every native host sends the same
/// request. The Apple `OpenRouterAPIClient` delegates here and supplies its AVFoundation
/// duration reader; hosts without one report `0`, which every consumer reads as unknown.
public struct OpenRouterInlineAudioTranscriptionClient: Sendable {
    /// Existing Apple adapters retain their legacy fallback; new hosts reject
    /// unknown formats rather than labelling an arbitrary container as M4A.
    public enum FormatPolicy: Sendable { case legacyM4AFallback, supportedFormatsOnly }

    public enum InputError: LocalizedError, Equatable {
        case unsupportedFormat
        public var errorDescription: String? {
            "This audio format is unsupported by OpenRouter audio-chat transcription. Use WAV, MP3 or M4A."
        }
    }

    public typealias DurationResolver = @Sendable (URL) async -> TimeInterval

    public static let defaultMaximumInlineAudioBytes: Int64 = 50 * 1024 * 1024

    /// The static batch catalogue entries this route serves: every remote entry whose
    /// canonical credential is the OpenRouter key. The `google/` and `openai/` prefixes are
    /// shared with direct Gemini and OpenAI routes, so ownership comes from the shared
    /// credential rule rather than from the identifier or a second platform list.
    public static let batchCatalogIDs: Set<String> = Set(
        ModelCatalog.batchTranscription.map(\.id).filter {
            ModelCredentialResolver.requirement(for: $0, purpose: .batchTranscription)
                == ModelCredentialResolver.openRouterRequirement
        }
    )

    private let apiKey: String
    private let session: URLSession
    private let maximumInlineAudioBytes: Int64
    private let branding: OpenRouterBranding
    private let durationResolver: DurationResolver
    private let formatPolicy: FormatPolicy

    public init(
        apiKey: String,
        session: URLSession = .shared,
        maximumInlineAudioBytes: Int64 = OpenRouterInlineAudioTranscriptionClient.defaultMaximumInlineAudioBytes,
        branding: OpenRouterBranding = .platformDefault,
        formatPolicy: FormatPolicy = .legacyM4AFallback,
        durationResolver: @escaping DurationResolver = { _ in 0 }
    ) {
        self.apiKey = apiKey
        self.session = session
        self.maximumInlineAudioBytes = maximumInlineAudioBytes
        self.branding = branding
        self.formatPolicy = formatPolicy
        self.durationResolver = durationResolver
    }

    public func transcribeFile(at url: URL, model: String, language: String?) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenRouterClientError.apiKeyMissing }
        let identifier = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try makeRequest(apiKey: key, audioURL: url, model: identifier, language: language)
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        let text = try Self.transcript(from: data, response: response)

        let duration = await usableDuration(of: url)
        try Task.checkCancellation()
        return TranscriptionResult(
            text: text,
            segments: [TranscriptionSegment(startTime: 0, endTime: duration, text: text)],
            confidence: nil,
            duration: duration,
            modelIdentifier: identifier,
            cost: nil,
            rawPayload: String(data: data, encoding: .utf8),
            debugInfo: nil
        )
    }

    // MARK: - Request shaping

    private func makeRequest(apiKey key: String, audioURL url: URL, model: String, language: String?) throws
        -> URLRequest {
        var request = URLRequest(url: OpenRouterService.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        branding.apply(to: &request)

        let format = try inputFormat(for: url)
        try enforceInlineAudioSizeLimit(for: url)
        // Read in bounded chunks even when a file grows after the metadata check.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let audioData = try Self.readAudio(from: handle, limit: maximumInlineAudioBytes)
        try Task.checkCancellation()
        request.httpBody = try JSONEncoder().encode(
            OpenRouterAudioTranscriptionRequest(
                model: model,
                temperature: 0,
                messages: [
                    OpenRouterAudioTranscriptionRequest.Message(
                        role: "user",
                        content: [
                            .text(Self.transcriptionPrompt(language: language)),
                            .inputAudio(
                                data: audioData.base64EncodedString(),
                                format: format
                            )
                        ]
                    )
                ],
                stream: false
            )
        )
        return request
    }

    /// The first non-empty choice, trimmed; a reply without one is invalid.
    private static func transcript(from data: Data, response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse else { throw OpenRouterClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterClientError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "<no-body>")
        }
        let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        guard let text = decoded.choices
            .compactMap({ $0.message?.content.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else {
            throw OpenRouterClientError.invalidResponse
        }
        return text
    }

    static func transcriptionPrompt(language: String?) -> String {
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedLanguage.isEmpty {
            return "Transcribe this audio file. Return only the transcript text, with no commentary."
        }

        return "Transcribe this audio file using locale \(trimmedLanguage). "
            + "Return only the transcript text, with no commentary."
    }

    private func inputFormat(for url: URL) throws -> String {
        if let format = Self.knownAudioInputFormat(for: url) { return format }
        guard case .legacyM4AFallback = formatPolicy else { throw InputError.unsupportedFormat }
        return "m4a"
    }

    static func audioInputFormat(for url: URL) -> String {
        knownAudioInputFormat(for: url) ?? "m4a"
    }

    private static func knownAudioInputFormat(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "wav", "mp3", "aiff", "aac", "ogg", "flac", "m4a", "pcm16", "pcm24":
            return ext
        case "m4b":
            return "m4a"
        case "wave":
            return "wav"
        default:
            return nil
        }
    }

    static func readAudio(from handle: FileHandle, limit: Int64) throws -> Data {
        var data = Data()
        while true {
            try Task.checkCancellation()
            // At the limit, read one byte to distinguish exact EOF from growth.
            let remaining = limit - Int64(data.count)
            guard remaining >= 0 else {
                throw OpenRouterClientError.audioFileTooLarge(fileSize: Int64(data.count), limit: limit)
            }
            let count = remaining >= 64 * 1024 ? 64 * 1024 : Int(remaining) + 1
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return data }
            guard Int64(chunk.count) <= remaining else {
                throw OpenRouterClientError.audioFileTooLarge(fileSize: Int64(data.count + chunk.count), limit: limit)
            }
            data.append(chunk)
        }
    }

    private func enforceInlineAudioSizeLimit(for url: URL) throws {
        let fileSize = try Self.audioFileSize(for: url)
        guard fileSize <= maximumInlineAudioBytes else {
            throw OpenRouterClientError.audioFileTooLarge(
                fileSize: fileSize,
                limit: maximumInlineAudioBytes
            )
        }
    }

    private static func audioFileSize(for url: URL) throws -> Int64 {
        if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(fileSize)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Duration is enrichment read from the local file after the provider replied. An
    /// unreadable, empty or non-finite value must not discard a transcript that already
    /// exists, so it degrades to `0`, which every consumer reads as unknown.
    private func usableDuration(of url: URL) async -> TimeInterval {
        let duration = await durationResolver(url)
        return duration.isFinite && duration > 0 ? duration : 0
    }
}

// MARK: - Wire models

private struct OpenRouterAudioTranscriptionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: [OpenRouterAudioContentPart]
    }

    let model: String
    let temperature: Double
    let messages: [Message]
    let stream: Bool
}

private enum OpenRouterAudioContentPart: Encodable {
    case text(String)
    case inputAudio(data: String, format: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case inputAudio = "input_audio"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputAudio(let data, let format):
            try container.encode("input_audio", forKey: .type)
            let inputAudio = OpenRouterInputAudio(data: data, format: format)
            try container.encode(inputAudio, forKey: .inputAudio)
        }
    }
}

private struct OpenRouterInputAudio: Encodable {
    let data: String
    let format: String
}
