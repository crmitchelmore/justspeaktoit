import Foundation

/// A model and its provider-specific voice, encoded without ambiguous slash splitting.
public struct OpenRouterSpeechSelection: Codable, Equatable, Sendable, Identifiable {
    public static let prefix = "openrouter/speech/"
    public let modelID: String
    public let voice: String?

    public init(modelID: String, voice: String? = nil) {
        self.modelID = modelID
        self.voice = voice
    }

    public var id: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return Self.prefix }
        return Self.prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(id: String) {
        guard id.hasPrefix(Self.prefix), id.utf8.count <= 4096 else { return nil }
        var encoded = String(id.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let selection = try? JSONDecoder().decode(Self.self, from: data),
              Self.isValidIdentifier(selection.modelID),
              selection.voice.map(Self.isValidVoice) ?? true,
              selection.id == id else { return nil }
        self = selection
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        OpenRouterTranscriptionSelection.isValidModelID(value)
    }

    static func isValidVoice(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

/// The caller owns the temporary MP3 file and must remove it after playback or cancellation.
public struct OpenRouterSpeechResult: Sendable {
    public let audioURL: URL
    /// The raw speech endpoint does not currently return a billable cost.
    public let cost: Decimal?

    public init(audioURL: URL, cost: Decimal? = nil) {
        self.audioURL = audioURL
        self.cost = cost
    }
}

public enum OpenRouterAudioError: LocalizedError, Equatable {
    case invalidInput
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case transportFailure
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "The OpenRouter audio request contains an invalid model, voice, or audio input."
        case .invalidResponse: return "OpenRouter returned an invalid audio response."
        case .responseTooLarge: return "The OpenRouter audio response exceeds the download limit."
        case .httpStatus(let status): return "OpenRouter audio request failed (HTTP \(status))."
        case .transportFailure: return "The OpenRouter audio request could not be completed."
        case .timedOut: return "The OpenRouter audio request timed out."
        }
    }
}
