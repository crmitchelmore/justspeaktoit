// swiftlint:disable file_length
import AVFoundation
import Foundation

/// Shared support for Meta Model API's dedicated speech-to-text endpoints.
/// This deliberately does not use the OpenAI-compatible text-model surface.
public enum MetaMuseVoiceTranscribe {
    public static let providerID = "meta"
    public static let modelID = "muse-voice-transcribe-1.0"
    public static let liveCatalogID = "meta/\(modelID)-streaming"
    public static let batchCatalogID = "meta/\(modelID)"
    public static let realtimeURL = URL(string: "wss://api.meta.ai/v1/asr/realtime")!
    public static let transcribeURL = URL(string: "https://api.meta.ai/v1/asr/transcribe")!
    public static let maximumAudioDuration: TimeInterval = 600
    public static let maximumRequestBytes = 32 * 1_024 * 1_024

    /// Meta accepts language names rather than BCP-47 codes. Unknown locales
    /// are omitted so the model can use automatic language detection.
    public static func languageBias(for language: String?) -> [String] {
        guard let language else { return [] }
        let code = language
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        let names: [String: String] = [
            "ar": "Arabic", "bn": "Bengali", "nl": "Dutch", "en": "English",
            "fr": "French", "de": "German", "he": "Hebrew", "hi": "Hindi",
            "id": "Indonesian", "it": "Italian", "ja": "Japanese", "kn": "Kannada",
            "ko": "Korean", "ms": "Malay", "zh": "Mandarin Chinese", "mr": "Marathi",
            "pl": "Polish", "pt": "Portuguese", "es": "Spanish", "fil": "Tagalog",
            "tl": "Tagalog", "ta": "Tamil", "te": "Telugu", "th": "Thai",
            "tr": "Turkish", "vi": "Vietnamese"
        ]
        return names[code].map { [$0] } ?? []
    }

    /// Parses comma/newline-separated recognition terms into Meta's keyword array.
    public static func keywords(from rawValue: String) -> [String] {
        var seen = Set<String>()
        return rawValue
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 100 }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(100)
            .map { $0 }
    }
}

public enum MetaMuseMode: String, Codable, Sendable {
    case pushToTalk = "PUSH_TO_TALK"
    case endpointing = "ENDPOINTING"
    case diarization = "DIARIZATION"
}

public struct MetaMuseTranscribeResponse: Codable, Sendable, Equatable {
    public struct Turn: Codable, Sendable, Equatable {
        public let turnId: Int
        public let startMs: Int
        public let endMs: Int
        public let transcript: String
        public let speaker: String?
    }

    public let sessionId: String
    public let transcript: String
    public let audioDurationMs: Int
    public let turns: [Turn]
}

public enum MetaMuseError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAudio(String)
    case requestTooLarge
    case authentication
    case rateLimited
    case streamingPolicy(String)
    case unavailable(String)
    case invalidResponse
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Meta Model API key is missing. Please configure it in Settings."
        case .invalidAudio(let detail):
            return "Meta Muse Voice Transcribe could not prepare this audio file: \(detail)"
        case .requestTooLarge:
            return "Meta Muse Voice Transcribe accepts recordings up to 10 minutes and request bodies under 32 MB."
        case .authentication:
            return "Meta Model API rejected the API key. Check it in Settings."
        case .rateLimited:
            return "Meta Model API is rate limited. Please wait and try again."
        case .streamingPolicy(let detail):
            return "Meta Muse Voice Transcribe rejected the streaming session: \(detail)"
        case .unavailable(let detail):
            return "Meta Muse Voice Transcribe is temporarily unavailable: \(detail)"
        case .invalidResponse:
            return "Meta Muse Voice Transcribe returned an invalid response."
        case .server(let status, let message):
            return "Meta Model API returned HTTP \(status): \(message)"
        }
    }

    public static func fromHTTPStatus(_ status: Int, body: String) -> MetaMuseError {
        switch status {
        case 400, 406, 415, 422: return .invalidAudio(body)
        case 401, 403: return .authentication
        case 413: return .requestTooLarge
        case 429: return .rateLimited
        case 500...599: return .unavailable(body)
        default: return .server(status: status, message: body)
        }
    }
}

/// Cross-platform batch/file client for Meta's dedicated transcription endpoint.
public struct MetaMuseBatchClient: Sendable {
    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = .shared, endpoint: URL = MetaMuseVoiceTranscribe.transcribeURL) {
        self.session = session
        self.endpoint = endpoint
    }

    public func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String = MetaMuseVoiceTranscribe.batchCatalogID,
        language: String?,
        keywords: [String] = []
    ) async throws -> TranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MetaMuseError.missingAPIKey }
        try Task.checkCancellation()
        let prepared = try await MetaMuseAudioPreparer.prepareWAV(at: url)
        guard prepared.data.count < MetaMuseVoiceTranscribe.maximumRequestBytes else {
            throw MetaMuseError.requestTooLarge
        }
        let request = try Self.makeRequest(
            endpoint: endpoint,
            apiKey: key,
            audio: prepared.data,
            filename: url.deletingPathExtension().lastPathComponent + ".wav",
            model: Self.apiModelName(from: model),
            mode: .endpointing,
            languageBias: MetaMuseVoiceTranscribe.languageBias(for: language),
            keywords: keywords
        )

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw MetaMuseError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw MetaMuseError.fromHTTPStatus(http.statusCode, body: Self.errorMessage(from: data))
            }
            guard let decoded = try? JSONDecoder().decode(MetaMuseTranscribeResponse.self, from: data) else {
                throw MetaMuseError.invalidResponse
            }
            return Self.result(from: decoded, model: model, payload: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    // Multipart construction keeps Meta's two required parts together.
    // swiftlint:disable:next function_parameter_count
    static func makeRequest(
        endpoint: URL,
        apiKey: String,
        audio: Data,
        filename: String,
        model: String,
        mode: MetaMuseMode,
        languageBias: [String],
        keywords: [String]
    ) throws -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var settings: [String: Any] = [
            "model": model,
            "audioEncoding": "WAV",
            "mode": mode.rawValue
        ]
        if !languageBias.isEmpty { settings["languageBias"] = languageBias }
        if !keywords.isEmpty { settings["keywords"] = keywords }
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        var body = Data()
        body.appendMultipartPart(
            name: "request", contentType: "application/json", data: settingsData, boundary: boundary
        )
        body.appendMultipartPart(
            name: "audio", filename: filename, contentType: "audio/wav", data: audio, boundary: boundary
        )
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    static func apiModelName(from model: String) -> String {
        var name = model.split(separator: "/").last.map(String.init) ?? model
        if name.hasSuffix("-streaming") { name.removeLast("-streaming".count) }
        return name
    }

    private static func result(
        from response: MetaMuseTranscribeResponse,
        model: String,
        payload: Data
    ) -> TranscriptionResult {
        let segments = response.turns.map { turn in
            let prefix = turn.speaker.map { "Speaker \($0): " } ?? ""
            return TranscriptionSegment(
                startTime: Double(turn.startMs) / 1_000,
                endTime: Double(turn.endMs) / 1_000,
                text: prefix + turn.transcript
            )
        }
        return TranscriptionResult(
            text: response.transcript,
            segments: segments.isEmpty && !response.transcript.isEmpty
                ? [TranscriptionSegment(
                    startTime: 0,
                    endTime: Double(response.audioDurationMs) / 1_000,
                    text: response.transcript
                )]
                : segments,
            confidence: nil,
            duration: Double(response.audioDurationMs) / 1_000,
            modelIdentifier: model,
            cost: nil,
            rawPayload: String(data: payload, encoding: .utf8),
            debugInfo: nil
        )
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (object["message"] as? String)
                ?? ((object["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "No response body"
        }
        return String(data: data, encoding: .utf8) ?? "No response body"
    }
}

public struct MetaMuseAPIKeyValidator: Sendable {
    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = .shared, endpoint: URL = MetaMuseVoiceTranscribe.transcribeURL) {
        self.session = session
        self.endpoint = endpoint
    }

    /// Probes the speech endpoint itself, proving Muse Voice Transcribe access.
    public func validate(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(message: "API key is empty") }
        do {
            let request = try MetaMuseBatchClient.makeRequest(
                endpoint: endpoint,
                apiKey: trimmed,
                audio: MetaMuseAudioPreparer.validationWAV,
                filename: "validation.wav",
                model: MetaMuseVoiceTranscribe.modelID,
                mode: .pushToTalk,
                languageBias: [],
                keywords: []
            )
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Received a non-HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .success(message: "Meta Model API key validated for Muse Voice Transcribe")
            }
            let mapped = MetaMuseError.fromHTTPStatus(
                http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "No response body"
            )
            return .failure(message: mapped.localizedDescription)
        } catch {
            return .failure(message: "Validation failed: \(error.localizedDescription)")
        }
    }
}

enum MetaMuseAudioPreparer {
    struct PreparedAudio {
        let data: Data
        let duration: TimeInterval
    }

    static let sampleRate = 16_000
    /// 80 ms of valid silence: enough for the endpoint to parse and authorize
    /// the request without charging for a meaningful transcription.
    static let validationWAV = wavData(
        pcm: Data(repeating: 0, count: sampleRate * 2 * 80 / 1_000),
        sampleRate: sampleRate
    )

    // Conversion is one bounded pipeline so cancellation always stops before upload.
    // swiftlint:disable:next function_body_length
    static func prepareWAV(at url: URL) async throws -> PreparedAudio {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: url)
        } catch {
            throw MetaMuseError.invalidAudio(error.localizedDescription)
        }
        let inputFormat = inputFile.processingFormat
        let duration = Double(inputFile.length) / inputFormat.sampleRate
        guard duration.isFinite, duration <= MetaMuseVoiceTranscribe.maximumAudioDuration else {
            throw MetaMuseError.requestTooLarge
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MetaMuseError.invalidAudio("The file's audio format could not be converted.")
        }

        var pcm = Data()
        let inputCapacity: AVAudioFrameCount = 8_192
        while inputFile.framePosition < inputFile.length {
            try Task.checkCancellation()
            guard let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: inputCapacity
            ) else {
                throw MetaMuseError.invalidAudio("An input conversion buffer could not be created.")
            }
            try inputFile.read(into: input)
            guard input.frameLength > 0 else { break }
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw MetaMuseError.invalidAudio("An output conversion buffer could not be created.")
            }
            var providedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !providedInput else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                providedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, conversionError == nil else {
                throw MetaMuseError.invalidAudio(conversionError?.localizedDescription ?? "Audio conversion failed.")
            }
            let buffer = output.audioBufferList.pointee.mBuffers
            guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            pcm.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize))
        }
        return PreparedAudio(data: wavData(pcm: pcm, sampleRate: sampleRate), duration: duration)
    }

    static func wavData(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        func appendASCII(_ value: String) { data.append(Data(value.utf8)) }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

private extension Data {
    mutating func appendMultipartPart(
        name: String,
        filename: String? = nil,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        let filenameValue = filename.map { "; filename=\"\($0)\"" } ?? ""
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\(filenameValue)\r\n".utf8))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}
