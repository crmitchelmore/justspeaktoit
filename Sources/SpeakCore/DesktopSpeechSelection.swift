import Foundation

public struct DesktopSpeechSelection: Equatable, Sendable {
    public let voice: DesktopSpeechVoice
    public let options: VoiceSynthesisOptions

    public init(voice: DesktopSpeechVoice, options: VoiceSynthesisOptions) throws {
        guard DesktopSpeechVoice.voices.contains(voice) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        try options.validate(for: voice.capabilities)
        self.voice = voice
        self.options = options
    }
}
