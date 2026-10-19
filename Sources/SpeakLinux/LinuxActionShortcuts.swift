import Foundation
import SpeakCore
import SpeakDesktopHost
import CLinuxSupport

enum LinuxActionShortcutRun: Equatable {
    case record, page(String), stop, troubleshooting, comparison, quickVoice(Int), unavailable

    // swiftlint:disable:next cyclomatic_complexity
    init(_ action: DesktopShortcutAction) {
        switch action {
        case .startStopRecording: self = .record
        case .openDashboard: self = .page(DesktopSidebarShortcut.dashboard.rawValue)
        case .showHistory: self = .page(DesktopSidebarShortcut.history.rawValue)
        case .openVoiceOutput, .openVoiceOutputSettings: self = .page(DesktopSidebarShortcut.voiceOutput.rawValue)
        case .openSettings, .openDataMigrationSettings: self = .page(DesktopSidebarShortcut.general.rawValue)
        case .openTranscriptionSettings: self = .page(DesktopSidebarShortcut.transcription.rawValue)
        case .openPostProcessingSettings: self = .page(DesktopSidebarShortcut.postProcessing.rawValue)
        case .openCorrections: self = .page(DesktopSidebarShortcut.corrections.rawValue)
        case .openPronunciationSettings: self = .page(DesktopSidebarShortcut.pronunciation.rawValue)
        case .openProfilesSettings: self = .page(DesktopSidebarShortcut.profiles.rawValue)
        case .openKeyboardSettings: self = .page("keyboard")
        case .openAboutSettings: self = .page(DesktopSidebarShortcut.about.rawValue)
        case .stopTTS: self = .stop
        case .openTroubleshooting: self = .troubleshooting
        case .openCompareModelsSettings: self = .comparison
        case .quickVoice1: self = .quickVoice(1)
        case .quickVoice2: self = .quickVoice(2)
        case .quickVoice3: self = .quickVoice(3)
        case .speakSelectedText, .speakClipboard, .pauseResumeTTS, .openAPIKeysSettings,
             .openPermissionsSettings, .pasteLastHistoryItem, .editSelectionByVoice:
            self = .unavailable
        }
    }

    var code: Int32 {
        switch self {
        case .unavailable: 0
        case .record: 1
        case .page: 2
        case .stop: 3
        case .troubleshooting: 4
        case .comparison: 5
        case .quickVoice: 6
        }
    }
    var page: String { if case .page(let name) = self { name } else { "" } }
    var slot: Int32 { if case .quickVoice(let slot) = self { Int32(slot) } else { 0 } }
}

extension LinuxWindow {
    static func configureActionShortcuts(_ holder: LinuxEventContext) async throws {
        let bindings = await holder.controller.shortcutBindings
        let strings = Strings()
        let rows = DesktopShortcutAction.allCases.map { action in
            let binding = bindings[action]
            let chord = binding.linuxChord
            let run = LinuxActionShortcutRun(action)
            let note = actionShortcutNote(action, bindings: bindings)
            let unset = binding.keyCode == 0 && binding.modifiers.isEmpty && !binding.isEnabled
            return JSTILinuxActionShortcut(
                title: strings.add(action.displayName),
                chord: strings.add(unset ? "Not set" : chord?.displayName ?? "Mac-specific key"),
                note: strings.add(note), page: strings.add(run.page), keysym: chord?.keysym ?? 0,
                modifiers: chord?.modifiers ?? 0, run: run.code, slot: run.slot,
                enabled: binding.isEnabled && !binding.isGlobal && chord != nil && run != .unavailable ? 1 : 0
            )
        }
        let result = withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer { jsti_window_set_action_shortcuts($0.baseAddress, $0.count) }
        }
        guard result == 0 else { throw DesktopHostError(message: "Linux action shortcuts could not be configured.") }
    }

    private static func actionShortcutNote(
        _ action: DesktopShortcutAction, bindings: DesktopShortcutBindings
    ) -> String {
        let binding = bindings[action]
        let run = LinuxActionShortcutRun(action)
        if !binding.isEnabled { return "Off" }
        if run == .unavailable { return "Not implemented on Linux yet. The binding stays saved." }
        if binding.isGlobal { return "Global action registration is not available yet. The binding stays saved." }
        guard let chord = binding.linuxChord else { return "This Mac-specific combination stays saved, not registered." }
        if chord.modifiers == DesktopShortcutLinuxChord.control,
           let sidebar = DesktopSidebarShortcut.allCases.first(where: { chord.keysym == UInt32(0x30 + $0.digit) }),
           run != .page(sidebar.rawValue) {
            return "This window. The \(sidebar.rawValue) sidebar shortcut uses this combination and runs first."
        }
        if let conflict = DesktopShortcutAction.allCases.first(where: {
            $0 != action && bindings[$0].isEnabled && !bindings[$0].isGlobal &&
                LinuxActionShortcutRun($0) != .unavailable && bindings[$0].linuxChord == chord
        }) {
            return "This window. Conflicts with \(conflict.displayName); the first listed action runs."
        }
        return "This window"
    }
}

extension LinuxActionShortcutRun {
    static func checkProjectionForSelfTest() throws {
        let expected: [(DesktopShortcutAction, Self)] = [
            (.openDashboard, .page("dashboard")), (.startStopRecording, .record),
            (.stopTTS, .stop), (.openSettings, .page("general")), (.showHistory, .page("history")),
            (.openVoiceOutput, .page("voice-output")), (.openCorrections, .page("corrections")),
            (.openTroubleshooting, .troubleshooting), (.openTranscriptionSettings, .page("transcription")),
            (.openPostProcessingSettings, .page("post-processing")), (.openDataMigrationSettings, .page("general")),
            (.openProfilesSettings, .page("profiles")), (.openVoiceOutputSettings, .page("voice-output")),
            (.openPronunciationSettings, .page("pronunciation")), (.openKeyboardSettings, .page("keyboard")),
            (.openCompareModelsSettings, .comparison), (.openAboutSettings, .page("about")),
            (.quickVoice1, .quickVoice(1)), (.quickVoice2, .quickVoice(2)), (.quickVoice3, .quickVoice(3))
        ]
        let unavailable: [DesktopShortcutAction] = [
            .speakSelectedText, .speakClipboard, .pauseResumeTTS, .openAPIKeysSettings,
            .openPermissionsSettings, .pasteLastHistoryItem, .editSelectionByVoice
        ]
        guard expected.allSatisfy({ Self($0.0) == $0.1 }),
              unavailable.allSatisfy({ Self($0) == .unavailable }),
              Set(expected.map(\.0) + unavailable) == Set(DesktopShortcutAction.allCases) else {
            throw DesktopHostError(
                message: "Linux action shortcut execution coverage differs from its declared projection."
            )
        }
    }
}
