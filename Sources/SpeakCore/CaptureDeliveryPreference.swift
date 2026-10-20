import Foundation

/// Capture readiness and delivery preferences shared with the Mac.
///
/// Defaults match the Mac. Desktop hosts apply only routes they implement:
/// idle capture preparation never opens the microphone, key-press warming
/// discards its audio, and remote paste reuses `RemoteTranscriptArrival`.
/// Streaming insertion and the History save interval are stored for
/// migration round trips; see Docs/desktop-settings-parity.md for the rules.
public enum CaptureDeliveryPreference {
    public static let defaultHistoryFlushInterval = 5.0

    public static let fields: [DesktopConfiguration.Field] = [
        .init(key: ApplicationPreferenceKey.audioPreWarmingEnabled.rawValue,
              title: "Prepare recording while idle (keeps the device ready; never opens the microphone)",
              group: "Transcription", kind: .boolean, defaultValue: AnyCodable(.bool(true))),
        .init(key: ApplicationPreferenceKey.warmMicrophoneOnKeyPress.rawValue,
              title: "Open the microphone on shortcut key press (hold/double-tap; unused audio is discarded)",
              group: "Keyboard", kind: .boolean, defaultValue: AnyCodable(.bool(true))),
        .init(key: ApplicationPreferenceKey.streamingInsertionEnabled.rawValue,
              title: "Stream text while dictating (Mac TextEdit/Notes only; inserted when dictation ends here)",
              group: "Output", kind: .boolean, defaultValue: AnyCodable(.bool(false))),
        .init(key: ApplicationPreferenceKey.pasteRemoteTranscriptsAtCursor.rawValue,
              title: "Paste fresh iPhone/Watch transcripts at the cursor when they sync",
              group: "Output", kind: .boolean, defaultValue: AnyCodable(.bool(false))),
        .init(key: ApplicationPreferenceKey.historyFlushInterval.rawValue,
              title: "Mac History save interval in seconds (History is saved immediately here)",
              group: "General", kind: .number(0...30),
              defaultValue: AnyCodable(.double(defaultHistoryFlushInterval)))
    ]
    public static let keys = Set(fields.map(\.key))
}

extension DesktopConfiguration {
    public var audioPreWarmingEnabled: Bool { enabled(ApplicationPreferenceKey.audioPreWarmingEnabled.rawValue) }
    public var warmMicrophoneOnKeyPress: Bool { enabled(ApplicationPreferenceKey.warmMicrophoneOnKeyPress.rawValue) }
    public var pasteRemoteTranscriptsAtCursor: Bool {
        enabled(ApplicationPreferenceKey.pasteRemoteTranscriptsAtCursor.rawValue)
    }
}
