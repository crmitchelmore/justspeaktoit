import Foundation

public struct DesktopSpeechSelection: Equatable, Sendable {
    public let voice: DesktopSpeechVoice
    public let options: VoiceSynthesisOptions
    public let accountInventory: VoiceAccountInventory?
    public let sonioxRegion: SonioxTTSRegion
    public let language: String?
    public var xaiInventory: XAIAccountVoiceInventory? { accountInventory?.xai }

    public init(voice: DesktopSpeechVoice, options: VoiceSynthesisOptions) throws {
        try self.init(voice: voice, options: options, xaiInventory: nil)
    }

    public init(voice: DesktopSpeechVoice, options: VoiceSynthesisOptions, xaiInventory: XAIAccountVoiceInventory?)
        throws {
        try self.init(voice: voice, options: options, accountInventory: xaiInventory.map(VoiceAccountInventory.xai))
    }

    public init(
        voice: DesktopSpeechVoice, options: VoiceSynthesisOptions, accountInventory: VoiceAccountInventory?,
        sonioxRegion: SonioxTTSRegion = .unitedStates, language: String? = nil
    ) throws {
        guard DesktopSpeechVoice.voices.contains(voice) || accountInventory?.contains(voice) == true else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        try options.validate(for: voice.capabilities)
        if case .soniox(let selected) = voice {
            try SonioxVoicePreference.validateLanguage(language)
            guard selected.accountVoice == nil || accountInventory?.soniox?.region == sonioxRegion else {
                throw VoiceAccountDiscoveryError.credentialChanged(.soniox)
            }
        }
        if case .gemini = voice { try DesktopGeminiSpeechSynthesis.validateLanguage(language) }
        self.voice = voice
        self.options = options
        self.accountInventory = accountInventory
        self.sonioxRegion = sonioxRegion
        self.language = language
    }
}
