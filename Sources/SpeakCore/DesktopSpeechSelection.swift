import Foundation

public struct DesktopSpeechSelection: Equatable, Sendable {
    public let voice: DesktopSpeechVoice
    public let options: VoiceSynthesisOptions
    public let xaiInventory: XAIAccountVoiceInventory?

    public init(voice: DesktopSpeechVoice, options: VoiceSynthesisOptions) throws {
        try self.init(voice: voice, options: options, xaiInventory: nil)
    }

    public init(voice: DesktopSpeechVoice, options: VoiceSynthesisOptions, xaiInventory: XAIAccountVoiceInventory?)
        throws {
        guard DesktopSpeechVoice.voices.contains(voice) || xaiInventory?.contains(voice) == true else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        try options.validate(for: voice.capabilities)
        self.voice = voice
        self.options = options
        self.xaiInventory = xaiInventory
    }
}
