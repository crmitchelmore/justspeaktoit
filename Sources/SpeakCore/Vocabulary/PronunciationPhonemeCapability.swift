/// Describes a TTS provider's SSML phoneme support independently of its host.
public protocol PronunciationPhonemeCapable {
    var supportsSSMLPhonemes: Bool { get }
    var phonemeAlphabet: String { get }
}

public enum PronunciationPhonemeCapability: Sendable, Equatable, PronunciationPhonemeCapable {
    case unsupported
    case ipa

    public var supportsSSMLPhonemes: Bool { self == .ipa }
    public var phonemeAlphabet: String { "ipa" }
}

extension DesktopSpeechVoice: PronunciationPhonemeCapable {
    /// SSML acceptance alone does not establish phoneme support (notably MAI).
    public var supportsSSMLPhonemes: Bool {
        if case .azureNeural = self { return PronunciationPhonemeCapability.ipa.supportsSSMLPhonemes }
        return PronunciationPhonemeCapability.unsupported.supportsSSMLPhonemes
    }

    public var phonemeAlphabet: String { PronunciationPhonemeCapability.ipa.phonemeAlphabet }
}
