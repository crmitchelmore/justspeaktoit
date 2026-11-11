import Foundation

/// Window-local navigation, independent of the global recording shortcut.
public enum DesktopSidebarShortcut: String, CaseIterable, Sendable {
    case dashboard
    case history
    case voiceOutput = "voice-output"
    case general
    case transcription
    case postProcessing = "post-processing"
    case corrections
    case pronunciation
    case profiles
    case about

    public static let showHintsByDefault = true

    public var digit: Int {
        switch self {
        case .dashboard: return 1
        case .history: return 2
        case .voiceOutput: return 3
        case .general: return 4
        case .transcription: return 5
        case .postProcessing: return 6
        case .corrections: return 7
        case .pronunciation: return 8
        case .profiles: return 9
        case .about: return 0
        }
    }

    public var chord: String { "Ctrl+\(digit)" }

}
