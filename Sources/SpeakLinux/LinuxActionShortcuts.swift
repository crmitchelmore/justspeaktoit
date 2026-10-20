import Foundation
import SpeakCore
import SpeakDesktopHost
import CLinuxSupport

enum LinuxActionShortcutRun: Equatable {
    case record, page(String), stop, troubleshooting, comparison, quickVoice(Int), clipboard, pauseSpeech
    case apiKeys, permissions, pasteLastHistory, selectedText, unavailable

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
        case .speakClipboard: self = .clipboard
        case .pauseResumeTTS: self = .pauseSpeech
        case .openAPIKeysSettings: self = .apiKeys
        case .openPermissionsSettings: self = .permissions
        case .pasteLastHistoryItem: self = .pasteLastHistory
        case .speakSelectedText: self = .selectedText
        case .editSelectionByVoice: self = .unavailable
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
        case .clipboard: 7
        case .pauseSpeech: 8
        case .apiKeys: 9
        case .permissions: 10
        case .pasteLastHistory: 11
        case .selectedText: 12
        }
    }
    var page: String { if case .page(let name) = self { name } else { "" } }
    var slot: Int32 { if case .quickVoice(let slot) = self { Int32(slot) } else { 0 } }
    var desktopCommandArgument: String? {
        switch self {
        case .record: JSTI_TOGGLE_ARGUMENT
        case .clipboard: JSTI_SPEAK_CLIPBOARD_ARGUMENT
        case .pasteLastHistory: JSTI_PASTE_LAST_HISTORY_ARGUMENT
        case .selectedText: JSTI_SPEAK_SELECTED_TEXT_ARGUMENT
        case .stop: JSTI_STOP_SPEECH_ARGUMENT
        case .pauseSpeech: JSTI_PAUSE_SPEECH_ARGUMENT
        case .quickVoice(1): JSTI_QUICK_VOICE_1_ARGUMENT
        case .quickVoice(2): JSTI_QUICK_VOICE_2_ARGUMENT
        case .quickVoice(3): JSTI_QUICK_VOICE_3_ARGUMENT
        default: nil
        }
    }

    static var forwardedCommandArguments: Set<String> {
        Set(DesktopShortcutAction.allCases.compactMap { Self($0).desktopCommandArgument })
            .subtracting([JSTI_TOGGLE_ARGUMENT])
    }
}

extension LinuxWindow {
    static func configureActionShortcuts(_ holder: LinuxEventContext) async throws {
        let bindings = await holder.controller.shortcutBindings
        let revision = LinuxActionShortcutEditorState.shared.configure(bindings)
        let strings = Strings()
        let rows = actionShortcutRows(bindings, strings: strings)
        let presets = DesktopShortcutPreset.allCases
        guard let reset = presets.firstIndex(of: .standard) else {
            throw DesktopHostError(message: "The canonical shortcut defaults are unavailable.")
        }
        let presetRows = presets.flatMap { actionShortcutRows(bindings.applying($0), strings: strings) }
        let names: [UnsafePointer<CChar>?] = presets.map { strings.add($0.displayName) }
        let result = withExtendedLifetime(strings) {
            let configured = rows.withUnsafeBufferPointer { jsti_window_set_action_shortcuts($0.baseAddress, $0.count) }
            guard configured == 0 else { return configured }
            return names.withUnsafeBufferPointer { names in
                presetRows.withUnsafeBufferPointer { entries in
                    revision.uuidString.withCString {
                        jsti_window_set_action_shortcut_editor(
                            $0, names.baseAddress, entries.baseAddress, presets.count, rows.count,
                            Int32(reset)
                        )
                    }
                }
            }
        }
        guard result == 0 else { throw DesktopHostError(message: "Linux action shortcuts could not be configured.") }
    }

    private static func actionShortcutRows(
        _ bindings: DesktopShortcutBindings, strings: Strings
    ) -> [JSTILinuxActionShortcut] {
        DesktopShortcutAction.allCases.map { action in
            let binding = bindings[action]
            let chord = binding.linuxChord
            let run = LinuxActionShortcutRun(action)
            let note = actionShortcutNote(action, bindings: bindings)
            let unset = binding.keyCode == 0 && binding.modifiers.isEmpty && !binding.isEnabled
            return JSTILinuxActionShortcut(
                title: strings.add(action.displayName),
                chord: strings.add(unset ? "Not set" : chord?.displayName ?? binding.windowsDisplayName),
                note: strings.add(note), page: strings.add(run.page), identifier: strings.add(action.rawValue),
                keysym: unset ? 0 : chord?.keysym ?? 0,
                modifiers: chord?.modifiers ?? 0, run: run.code, slot: run.slot,
                enabled: binding.isEnabled && !binding.isGlobal && chord != nil
                    && run != .unavailable && run != .selectedText ? 1 : 0,
                binding_enabled: binding.isEnabled ? 1 : 0, binding_global: binding.isGlobal ? 1 : 0,
                can_be_global: action.supportsGlobalShortcut ? 1 : 0, has_key: unset ? 0 : 1
            )
        }
    }

    private static func actionShortcutNote(
        _ action: DesktopShortcutAction, bindings: DesktopShortcutBindings
    ) -> String {
        let binding = bindings[action]
        let run = LinuxActionShortcutRun(action)
        if !binding.isEnabled { return "Off" }
        if run == .unavailable { return "Not implemented on Linux yet. The binding stays saved." }
        if run == .selectedText {
            return "External editable AT-SPI fields only. Allow session access in Voice Output, then bind "
                + "`\(LinuxShortcuts.toggleCommand) \(JSTI_SPEAK_SELECTED_TEXT_ARGUMENT)` "
                + "in desktop keyboard settings. This app's fields are excluded; the saved binding "
                + "is not registered automatically."
        }
        if binding.isGlobal {
            if let argument = run.desktopCommandArgument {
                return "Bind `\(LinuxShortcuts.toggleCommand) \(argument)` in your desktop's keyboard settings. "
                    + "Keep the app running; this saved global binding is not registered automatically."
            }
            return "Global action registration is not available yet. The binding stays saved."
        }
        guard let chord = binding.linuxChord else {
            return "This Mac-specific combination stays saved, not registered."
        }
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
        if let argument = run.desktopCommandArgument, run != .record {
            return "This window. You can also bind `\(LinuxShortcuts.toggleCommand) \(argument)` "
                + "in desktop keyboard settings while the app is running."
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
            (.quickVoice1, .quickVoice(1)), (.quickVoice2, .quickVoice(2)), (.quickVoice3, .quickVoice(3)),
            (.speakClipboard, .clipboard), (.pauseResumeTTS, .pauseSpeech), (.openAPIKeysSettings, .apiKeys),
            (.openPermissionsSettings, .permissions), (.pasteLastHistoryItem, .pasteLastHistory),
            (.speakSelectedText, .selectedText)
        ]
        let unavailable: [DesktopShortcutAction] = [
            .editSelectionByVoice
        ]
        guard expected.allSatisfy({ Self($0.0) == $0.1 }),
              unavailable.allSatisfy({ Self($0) == .unavailable }),
              Self(.pasteLastHistoryItem).code == 11,
              Self(.pasteLastHistoryItem).page.isEmpty, Self(.pasteLastHistoryItem).slot == 0,
              Self(.speakSelectedText).code == 12, Self(.speakSelectedText).slot == 0,
              desktopCommandProjectionIsValid(),
              Set(expected.map(\.0) + unavailable) == Set(DesktopShortcutAction.allCases) else {
            throw DesktopHostError(
                message: "Linux action shortcut execution coverage differs from its declared projection."
            )
        }
    }

    private static func desktopCommandProjectionIsValid() -> Bool {
        let expected: [(DesktopShortcutAction, String)] = [
            (.startStopRecording, JSTI_TOGGLE_ARGUMENT),
            (.speakClipboard, JSTI_SPEAK_CLIPBOARD_ARGUMENT),
            (.pasteLastHistoryItem, JSTI_PASTE_LAST_HISTORY_ARGUMENT),
            (.speakSelectedText, JSTI_SPEAK_SELECTED_TEXT_ARGUMENT),
            (.stopTTS, JSTI_STOP_SPEECH_ARGUMENT), (.pauseResumeTTS, JSTI_PAUSE_SPEECH_ARGUMENT),
            (.quickVoice1, JSTI_QUICK_VOICE_1_ARGUMENT), (.quickVoice2, JSTI_QUICK_VOICE_2_ARGUMENT),
            (.quickVoice3, JSTI_QUICK_VOICE_3_ARGUMENT)
        ]
        return expected.allSatisfy { Self($0.0).desktopCommandArgument == $0.1 }
            && Set(expected.map(\.1)) == forwardedCommandArguments.union([JSTI_TOGGLE_ARGUMENT])
            && Self.quickVoice(0).desktopCommandArgument == nil && Self.quickVoice(4).desktopCommandArgument == nil
    }
}
