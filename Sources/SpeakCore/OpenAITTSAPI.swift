import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenAITTSOutputFormat: String, Sendable {
    case mp3, aac, wav
}

public struct OpenAITTSRequest: Sendable {
    public let model: OpenAITTSModel
    public let voiceID: String
    public let speed: Double
    public let format: OpenAITTSOutputFormat

    public init(
        model: OpenAITTSModel, voiceID: String, speed: Double = 1, format: OpenAITTSOutputFormat = .wav
    ) {
        self.model = model
        self.voiceID = voiceID
        self.speed = speed
        self.format = format
    }
}

public enum OpenAITTSAPI {
    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    public static let maximumInputScalars = 4_096
    public static let speedRange: ClosedRange<Double> = 0.25...4

    public static func validate(text: String, request: OpenAITTSRequest) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAITTSAPIError.emptyText
        }
        guard text.unicodeScalars.count <= maximumInputScalars else { throw OpenAITTSAPIError.inputTooLarge }
        guard let voice = OpenAITTSCatalog.voice(forID: request.voiceID), voice.supports(request.model) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        guard request.speed.isFinite, speedRange.contains(request.speed) else {
            throw VoiceSynthesisConfigurationError.unsupportedSpeed(
                minimum: speedRange.lowerBound, maximum: speedRange.upperBound)
        }
    }

    public static func synthesisRequest(
        text: String, apiKey: String, request: OpenAITTSRequest
    ) throws -> URLRequest {
        try validate(text: text, request: request)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAITTSAPIError.missingCredential }
        guard let voice = OpenAITTSCatalog.voice(forID: request.voiceID) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        var result = URLRequest(url: endpoint)
        result.httpMethod = "POST"
        result.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.model.rawValue, "input": text, "voice": voice.id,
            "speed": request.speed, "response_format": request.format.rawValue
        ])
        return result
    }

    public static func synthesisSegments(_ text: String) throws -> [String] {
        let segments = SpeechTextSegmenter.segments(text, limit: maximumInputScalars)
        guard !segments.isEmpty else { throw OpenAITTSAPIError.emptyText }
        guard segments.allSatisfy({ $0.unicodeScalars.count <= maximumInputScalars }) else {
            throw OpenAITTSAPIError.inputTooLarge
        }
        return segments
    }
}

public enum OpenAITTSAPIError: LocalizedError, Equatable {
    case emptyText, inputTooLarge, missingCredential, service(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyText: "There is no text to speak."
        case .inputTooLarge:
            "An OpenAI speech request exceeds 4,096 characters. Shorten it without splitting a grapheme."
        case .missingCredential: "Save the separate OpenAI TTS key in Settings to use OpenAI Voice output."
        case .service(401): "OpenAI rejected the saved TTS key. Check the separate TTS key in Settings."
        case .service(403): "OpenAI refused speech access. Check the key's model permissions."
        case .service(429): "OpenAI speech quota or rate limit reached. Check the account quota."
        case .service(let status): "OpenAI speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
