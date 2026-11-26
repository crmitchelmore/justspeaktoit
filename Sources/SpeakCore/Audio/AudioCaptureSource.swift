import Foundation

/// Which audio source a capture session records.
///
/// Raw values are the stable wire contract shared by the automation socket,
/// the `speak` CLI (`--source`), MCP (`start_dictation`), and History metadata.
public enum AudioCaptureSource: String, Codable, Hashable, Sendable, CaseIterable {
    case mic
    case system
    case both

    public var includesMicrophone: Bool {
        self == .mic || self == .both
    }

    public var includesSystemAudio: Bool {
        self == .system || self == .both
    }

    public var displayName: String {
        switch self {
        case .mic: "Microphone"
        case .system: "System Audio"
        case .both: "Mic + System Audio"
        }
    }
}
