import Foundation

public struct DesktopSpeechSelection: Equatable, Sendable {
    public let voice: DesktopSpeechVoice
    public let options: VoiceSynthesisOptions
    public let accountInventory: VoiceAccountInventory?
    public var xaiInventory: XAIAccountVoiceInventory? { accountInventory?.xai }

    public init(voice: DesktopSpeechVoice, options: VoiceSynthesisOptions) throws {
        try self.init(voice: voice, options: options, xaiInventory: nil)
    }

    public init(voice: DesktopSpeechVoice, options: VoiceSynthesisOptions, xaiInventory: XAIAccountVoiceInventory?)
        throws {
        try self.init(voice: voice, options: options, accountInventory: xaiInventory.map(VoiceAccountInventory.xai))
    }

    public init(voice: DesktopSpeechVoice, options: VoiceSynthesisOptions, accountInventory: VoiceAccountInventory?)
        throws {
        guard DesktopSpeechVoice.voices.contains(voice) || accountInventory?.contains(voice) == true else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        try options.validate(for: voice.capabilities)
        self.voice = voice
        self.options = options
        self.accountInventory = accountInventory
    }
}
