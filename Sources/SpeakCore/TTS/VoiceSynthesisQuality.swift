import Foundation

/// The Mac's persisted quality identifiers and presentation, shared by native hosts.
public enum VoiceSynthesisQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, high, highest

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "Fast (Low Latency)"
        case .high: "Balanced"
        case .highest: "Best Quality"
        }
    }

    public var description: String {
        switch self {
        case .standard: "Optimized for speed, ~75ms latency"
        case .high: "Good balance of quality and speed"
        case .highest: "Maximum quality, higher latency"
        }
    }

    public var sampleRate: Int {
        switch self {
        case .standard: 16_000
        case .high: 24_000
        case .highest: 48_000
        }
    }

    public static let defaultValue: Self = .high
    public var neuralSampleRate: Int { self == .highest ? Self.highest.sampleRate : Self.high.sampleRate }

    public static func storedValue(_ identifier: String?) throws -> Self? {
        guard let identifier else { return nil }
        guard let quality = Self(rawValue: identifier) else {
            throw VoiceSynthesisConfigurationError.unsupportedQuality
        }
        return quality
    }
}

extension DesktopSpeechVoice {
    public var supportsQualityControls: Bool {
        switch self {
        case .elevenlabs(let model, _): model != ElevenLabsTTSModels.elevenV3
        case .openai, .cartesia, .soniox, .deepgram, .azureNeural, .azureMAI: true
        default: false
        }
    }

    /// Quality selects the same OpenAI model as the Mac; it never substitutes
    /// a different voice to make an incompatible model/voice pair work.
    public func applyingQuality(_ quality: VoiceSynthesisQuality?) throws -> Self {
        guard let quality else { return self }
        switch self {
        case .openai(_, let voice):
            let model = try OpenAITTSCatalog.model(forQualityIdentifier: quality.rawValue)
            guard voice.supports(model) else { throw VoiceSynthesisConfigurationError.unsupportedVoice }
            return .openai(model, voice)
        case .elevenlabs(let model, let voice):
            guard ElevenLabsTTSModels.all.contains(model), ElevenLabsTTSCatalog.voices.contains(voice) else {
                throw VoiceSynthesisConfigurationError.unsupportedVoice
            }
            // Explicit v3 is also the fallback target, not a fourth Mac quality.
            return model == ElevenLabsTTSModels.elevenV3 ? self : .elevenlabs(
                ElevenLabsTTSModels.model(for: quality), voice)
        default: return self
        }
    }

    public var defaultQuality: VoiceSynthesisQuality {
        if case .openai(let model, _) = self {
            return model.quality
        }
        if case .elevenlabs(let model, _) = self {
            if model == ElevenLabsTTSModels.flashV25 { return .standard }
            if model == ElevenLabsTTSModels.elevenV4 { return .highest }
        }
        return .defaultValue
    }

    public func sampleRate(quality: VoiceSynthesisQuality?) -> Int {
        let quality = quality ?? .defaultValue
        switch self {
        case .cartesia, .soniox: return quality.sampleRate
        case .deepgram, .azureNeural, .azureMAI:
            return quality.neuralSampleRate
        default: return sampleRate
        }
    }

    public var qualityTitle: String {
        switch self {
        case .openai: "Quality (selects the compatible OpenAI model)"
        case .elevenlabs(let model, _):
            model == ElevenLabsTTSModels.elevenV3
                ? "Quality (stored; fixed format, explicit Eleven v3 model)" : "Quality (selects the ElevenLabs model)"
        case .cartesia, .soniox: "Quality (16 / 24 / 48 kHz PCM)"
        case .deepgram, .azureNeural, .azureMAI: "Quality (24 kHz; Best Quality uses 48 kHz PCM)"
        default: "Quality (stored; selected provider uses a fixed format)"
        }
    }
}
