/// Per-generation choices, captured at admission rather than read mid-flight.
public struct VoiceGenerationOptions: Equatable, Sendable {
    public let autoPlay: Bool
    public let saveToRecordings: Bool
    public let format: VoiceAudioFormat?

    public init(autoPlay: Bool, saveToRecordings: Bool) {
        self.init(autoPlay: autoPlay, saveToRecordings: saveToRecordings, format: nil)
    }

    public init(autoPlay: Bool, saveToRecordings: Bool, format: VoiceAudioFormat?) {
        self.autoPlay = autoPlay
        self.saveToRecordings = saveToRecordings
        self.format = format
    }

    public var nativeFlags: Int32 { (autoPlay ? 1 : 0) | (saveToRecordings ? 2 : 0) }

    public init?(nativeFlags: Int32) {
        guard (0...3).contains(nativeFlags) else { return nil }
        self.init(autoPlay: nativeFlags & 1 != 0, saveToRecordings: nativeFlags & 2 != 0)
    }
}
