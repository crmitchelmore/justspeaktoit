/// Playback and archival defaults for a completed generated-speech result.
/// Explicit Read aloud is a separate operation, not gated by auto-play.
public enum SpeechGenerationDefaults {
    public static let autoPlay = true
    public static let saveToRecordings = false
}
