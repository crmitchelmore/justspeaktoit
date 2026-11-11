import AppKit
import Foundation
import SpeakCore

/// Represents a keyboard shortcut action that can be triggered globally or locally.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case openDashboard
    case startStopRecording
    case speakSelectedText
    case speakClipboard
    case pauseResumeTTS
    case stopTTS
    case openSettings
    case showHistory
    case openVoiceOutput
    case openCorrections
    case openTroubleshooting
    case openTranscriptionSettings
    case openPostProcessingSettings
    case openDataMigrationSettings
    case openProfilesSettings
    case openVoiceOutputSettings
    case openPronunciationSettings
    case openAPIKeysSettings
    case openKeyboardSettings
    case openPermissionsSettings
    case openCompareModelsSettings
    case openAboutSettings
    case quickVoice1
    case quickVoice2
    case quickVoice3
    case pasteLastHistoryItem
    case editSelectionByVoice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openDashboard: return "Open Dashboard"
        case .startStopRecording: return "Start/Stop Recording"
        case .speakSelectedText: return "Speak Selected Text"
        case .speakClipboard: return "Speak Clipboard Content"
        case .pauseResumeTTS: return "Pause/Resume TTS"
        case .stopTTS: return "Stop TTS"
        case .openSettings: return "Open General Settings"
        case .showHistory: return "Show History"
        case .openVoiceOutput: return "Open Voice Output"
        case .openCorrections: return "Open Corrections"
        case .openTroubleshooting: return "Open Troubleshooting"
        case .openTranscriptionSettings: return "Open Transcription Settings"
        case .openPostProcessingSettings: return "Open Post-processing Settings"
        case .openDataMigrationSettings: return "Open Data & Migration"
        case .openProfilesSettings: return "Open Profiles Settings"
        case .openVoiceOutputSettings: return "Open Voice Output Settings"
        case .openPronunciationSettings: return "Open Pronunciation Settings"
        case .openAPIKeysSettings: return "Open API Keys Settings"
        case .openKeyboardSettings: return "Open Keyboard Settings"
        case .openPermissionsSettings: return "Open Permissions Settings"
        case .openCompareModelsSettings: return "Open Compare Models"
        case .openAboutSettings: return "Open About Settings"
        case .quickVoice1: return "Quick Switch Voice 1"
        case .quickVoice2: return "Quick Switch Voice 2"
        case .quickVoice3: return "Quick Switch Voice 3"
        case .pasteLastHistoryItem: return "Paste Last History Item"
        case .editSelectionByVoice: return "Edit Selection by Voice"
        }
    }

    var defaultKeyBinding: KeyBinding {
        switch self {
        case .openDashboard:
            return KeyBinding(keyCode: 2, modifiers: [.command], isGlobal: false)  // ⌘D
        case .startStopRecording:
            return KeyBinding(
                keyCode: 1, modifiers: [.command, .shift], isGlobal: isGlobalByDefault
            )  // ⌘+Shift+S
        case .speakSelectedText:
            return KeyBinding(keyCode: 17, modifiers: [.command, .shift])  // ⌘+Shift+T
        case .speakClipboard:
            return KeyBinding(keyCode: 9, modifiers: [.command, .shift])  // ⌘+Shift+V
        case .pauseResumeTTS:
            return KeyBinding(keyCode: 49, modifiers: [], isGlobal: false)  // Space
        case .stopTTS:
            return KeyBinding(keyCode: 53, modifiers: [], isGlobal: false)  // Escape
        case .openSettings:
            return KeyBinding(keyCode: 18, modifiers: [.command], isGlobal: false)  // ⌘1
        case .showHistory:
            return KeyBinding(keyCode: 16, modifiers: [.command], isGlobal: false)  // ⌘Y
        case .openVoiceOutput:
            return KeyBinding(keyCode: 32, modifiers: [.command], isGlobal: false)  // ⌘U
        case .openCorrections:
            return KeyBinding(keyCode: 40, modifiers: [.command], isGlobal: false)  // ⌘K
        case .openTroubleshooting:
            return KeyBinding(keyCode: 17, modifiers: [.command], isGlobal: false)  // ⌘T
        case .openTranscriptionSettings:
            return KeyBinding(keyCode: 19, modifiers: [.command], isGlobal: false)  // ⌘2
        case .openPostProcessingSettings:
            return KeyBinding(keyCode: 20, modifiers: [.command], isGlobal: false)  // ⌘3
        case .openDataMigrationSettings:
            return KeyBinding(keyCode: 29, modifiers: [.command], isGlobal: false)  // ⌘0
        case .openProfilesSettings:
            return KeyBinding(keyCode: 24, modifiers: [.command, .shift], isGlobal: false)  // ⌘+
        case .openVoiceOutputSettings:
            return KeyBinding(keyCode: 21, modifiers: [.command], isGlobal: false)  // ⌘4
        case .openPronunciationSettings:
            return KeyBinding(keyCode: 23, modifiers: [.command], isGlobal: false)  // ⌘5
        case .openAPIKeysSettings:
            return KeyBinding(keyCode: 22, modifiers: [.command], isGlobal: false)  // ⌘6
        case .openKeyboardSettings:
            return KeyBinding(keyCode: 26, modifiers: [.command], isGlobal: false)  // ⌘7
        case .openPermissionsSettings:
            return KeyBinding(keyCode: 28, modifiers: [.command], isGlobal: false)  // ⌘8
        case .openCompareModelsSettings:
            return KeyBinding(keyCode: 25, modifiers: [.command], isGlobal: false)  // ⌘9
        case .openAboutSettings:
            return KeyBinding(keyCode: 27, modifiers: [.command], isGlobal: false)  // ⌘-
        case .quickVoice1:
            return KeyBinding(keyCode: 18, modifiers: [.command, .option], isGlobal: false)  // ⌘⌥1
        case .quickVoice2:
            return KeyBinding(keyCode: 19, modifiers: [.command, .option], isGlobal: false)  // ⌘⌥2
        case .quickVoice3:
            return KeyBinding(keyCode: 20, modifiers: [.command, .option], isGlobal: false)  // ⌘⌥3
        case .pasteLastHistoryItem:
            return KeyBinding(keyCode: 9, modifiers: [.command, .option])  // ⌥⌘V
        case .editSelectionByVoice:
            return KeyBinding(keyCode: 14, modifiers: [.command, .option])  // ⌥⌘E
        }
    }

    var legacyDefaultKeyBindings: [KeyBinding] {
        switch self {
        case .startStopRecording:
            // Migrates users who still hold the shipped global ⇧⌘S they never chose.
            // `loadBindings` only rewrites a binding that still matches a shipped default,
            // so anyone who re-bound or already toggled Global keeps their own setting.
            return [KeyBinding(keyCode: 1, modifiers: [.command, .shift], isGlobal: true)]
        case .openDashboard:
            return [KeyBinding(keyCode: 18, modifiers: [.command, .option], isGlobal: false)]
        case .showHistory:
            return [KeyBinding(keyCode: 19, modifiers: [.command, .option], isGlobal: false)]
        case .openVoiceOutput:
            return [KeyBinding(keyCode: 20, modifiers: [.command, .option], isGlobal: false)]
        case .openCorrections:
            return [KeyBinding(keyCode: 21, modifiers: [.command, .option], isGlobal: false)]
        case .openTroubleshooting:
            return [KeyBinding(keyCode: 23, modifiers: [.command, .option], isGlobal: false)]
        case .openSettings:
            return [KeyBinding(keyCode: 43, modifiers: [.command], isGlobal: false)]
        case .openTranscriptionSettings:
            return [KeyBinding(keyCode: 18, modifiers: [.command, .option, .shift], isGlobal: false)]
        case .openPostProcessingSettings:
            return [KeyBinding(keyCode: 19, modifiers: [.command, .option, .shift], isGlobal: false)]
        case .openProfilesSettings:
            return [KeyBinding(keyCode: 29, modifiers: [.command], isGlobal: false)]
        case .openDataMigrationSettings, .openCompareModelsSettings:
            return [KeyBinding(keyCode: 0, modifiers: [], isGlobal: false, isEnabled: false)]
        case .openVoiceOutputSettings:
            return [KeyBinding(keyCode: 20, modifiers: [.command, .option, .shift], isGlobal: false)]
        case .openPronunciationSettings:
            return [KeyBinding(keyCode: 21, modifiers: [.command, .option, .shift], isGlobal: false)]
        case .openAPIKeysSettings:
            return [KeyBinding(keyCode: 23, modifiers: [.command, .option, .shift], isGlobal: false)]
        case .openKeyboardSettings:
            return [KeyBinding(keyCode: 22, modifiers: [.command, .option, .shift], isGlobal: false)]
        case .openPermissionsSettings:
            return [KeyBinding(keyCode: 26, modifiers: [.command, .option, .shift], isGlobal: false)]
        case .openAboutSettings:
            return [
                KeyBinding(keyCode: 25, modifiers: [.command], isGlobal: false),
                KeyBinding(keyCode: 28, modifiers: [.command, .option, .shift], isGlobal: false)
            ]
        case .quickVoice1:
            return [KeyBinding(keyCode: 18, modifiers: [.command], isGlobal: false)]
        case .quickVoice2:
            return [KeyBinding(keyCode: 19, modifiers: [.command], isGlobal: false)]
        case .quickVoice3:
            return [KeyBinding(keyCode: 20, modifiers: [.command], isGlobal: false)]
        default:
            return []
        }
    }

    /// Whether the action can be registered system-wide at all.
    ///
    /// Drives which settings card the action appears under and whether it offers a Global
    /// toggle, so an action must stay here even when it ships non-global — otherwise the
    /// user loses the only control that can turn it back on.
    var supportsGlobalShortcut: Bool {
        switch self {
        case .startStopRecording, .speakSelectedText, .speakClipboard, .pasteLastHistoryItem,
             .editSelectionByVoice:
            return true
        default:
            return false
        }
    }

    /// Whether a fresh install registers it system-wide.
    ///
    /// `startStopRecording` is deliberately absent. The configured hotkey is already a
    /// system-wide way to record; shipping ⇧⌘S as a second global trigger gave users a
    /// recording shortcut they never asked for, on a chord many apps use for Save As. It
    /// stays bound, still works while the app is focused, and the Global toggle is still
    /// there for anyone who wants it back.
    var isGlobalByDefault: Bool {
        switch self {
        case .speakSelectedText, .speakClipboard, .pasteLastHistoryItem,
             .editSelectionByVoice:
            return true
        default:
            return false
        }
    }

    /// The build capability this action needs, or nil when every channel has it.
    var requiredChannelFeature: ChannelFeature? {
        switch self {
        case .editSelectionByVoice:
            return .voiceEdit
        default:
            return nil
        }
    }

    /// Whether this action can work in `channel`. Unavailable actions are never
    /// registered, dispatched or listed, so a build does not offer a flow that
    /// can only end in "Nothing to edit" (issue #673).
    func isAvailable(in channel: DistributionChannel) -> Bool {
        guard let feature = requiredChannelFeature else { return true }
        return channel.supports(feature)
    }

    static func availableCases(in channel: DistributionChannel = .current) -> [ShortcutAction] {
        allCases.filter { $0.isAvailable(in: channel) }
    }
}
