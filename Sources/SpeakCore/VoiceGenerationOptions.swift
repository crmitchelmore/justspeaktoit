/// Per-generation choices, captured at admission rather than read mid-flight.
public struct VoiceGenerationOptions: Equatable, Sendable {
    public let autoPlay: Bool
    public let saveToRecordings: Bool

    public init(autoPlay: Bool, saveToRecordings: Bool) {
        self.autoPlay = autoPlay
        self.saveToRecordings = saveToRecordings
    }

    public var nativeFlags: Int32 { (autoPlay ? 1 : 0) | (saveToRecordings ? 2 : 0) }

    public init?(nativeFlags: Int32) {
        guard (0...3).contains(nativeFlags) else { return nil }
        self.init(autoPlay: nativeFlags & 1 != 0, saveToRecordings: nativeFlags & 2 != 0)
    }
}
