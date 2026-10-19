import Foundation
import SpeakCore
import SpeakDesktopHost
import CWindowsSupport

extension WindowsHostPlatform {
    /// Windows applies the Mac's action shortcuts, so import and export report
    /// them as supported rather than preserved.
    package static var shortcutConfigurationKeys: Set<String> { [DesktopShortcutBindings.preferenceKey] }
}

/// How Windows performs each shared action. Actions with no Windows feature
/// yet keep their bindings for the Mac and are shown as Mac only.
enum WindowsActionShortcutRun: Equatable {
    case macOnly, record, page(String), playPause, stopSpeech, apiKeys, permissions, compareModels
    case quickVoice(Int), pasteLastHistoryItem

    init(_ action: DesktopShortcutAction) {
        switch action {
        case .startStopRecording: self = .record
        case .pauseResumeTTS: self = .playPause
        case .stopTTS: self = .stopSpeech
        case .openDashboard: self = .page(DesktopSidebarShortcut.dashboard.rawValue)
        case .showHistory: self = .page(DesktopSidebarShortcut.history.rawValue)
        case .openVoiceOutput, .openVoiceOutputSettings: self = .page(DesktopSidebarShortcut.voiceOutput.rawValue)
        case .openSettings: self = .page(DesktopSidebarShortcut.general.rawValue)
        case .openTranscriptionSettings: self = .page(DesktopSidebarShortcut.transcription.rawValue)
        case .openPostProcessingSettings: self = .page(DesktopSidebarShortcut.postProcessing.rawValue)
        case .openCorrections: self = .page(DesktopSidebarShortcut.corrections.rawValue)
        case .openPronunciationSettings: self = .page(DesktopSidebarShortcut.pronunciation.rawValue)
        case .openProfilesSettings: self = .page(DesktopSidebarShortcut.profiles.rawValue)
        case .openKeyboardSettings: self = .page("keyboard")
        case .openAboutSettings: self = .page(DesktopSidebarShortcut.about.rawValue)
        // Windows keeps backup, export and inspection on General.
        case .openDataMigrationSettings: self = .page(DesktopSidebarShortcut.general.rawValue)
        case .openAPIKeysSettings: self = .apiKeys
        case .openPermissionsSettings: self = .permissions
        case .openCompareModelsSettings: self = .compareModels
        case .quickVoice1: self = .quickVoice(1)
        case .quickVoice2: self = .quickVoice(2)
        case .quickVoice3: self = .quickVoice(3)
        case .pasteLastHistoryItem: self = .pasteLastHistoryItem
        case .speakSelectedText, .speakClipboard, .openTroubleshooting, .editSelectionByVoice:
            self = .macOnly
        }
    }

    static let runnable = Set(DesktopShortcutAction.allCases.filter { WindowsActionShortcutRun($0) != .macOnly })

    var code: Int32 {
        switch self {
        case .macOnly: return Int32(JSTI_ACTION_RUN_NONE)
        case .record: return Int32(JSTI_ACTION_RUN_RECORD)
        case .page: return Int32(JSTI_ACTION_RUN_PAGE)
        case .playPause: return Int32(JSTI_ACTION_RUN_PLAY_PAUSE)
        case .stopSpeech: return Int32(JSTI_ACTION_RUN_STOP_SPEECH)
        case .apiKeys: return Int32(JSTI_ACTION_RUN_API_KEYS)
        case .permissions: return Int32(JSTI_ACTION_RUN_PERMISSIONS)
        case .compareModels: return Int32(JSTI_ACTION_RUN_COMPARE)
        case .quickVoice(1): return Int32(JSTI_ACTION_RUN_QUICK_VOICE_1)
        case .quickVoice(2): return Int32(JSTI_ACTION_RUN_QUICK_VOICE_2)
        case .quickVoice: return Int32(JSTI_ACTION_RUN_QUICK_VOICE_3)
        case .pasteLastHistoryItem: return Int32(JSTI_ACTION_RUN_PASTE_LAST_HISTORY)
        }
    }

    var page: String {
        if case .page(let name) = self { return name }
        return ""
    }

    static let macOnlyNote = "Saved for your Mac; Windows cannot run this action yet."
}

/// What the dialog's check reads on the UI thread without waiting for the
/// controller: the bindings last configured and the dictation shortcut.
private final class WindowsActionShortcutState: @unchecked Sendable {
    static let shared = WindowsActionShortcutState()
    private let lock = NSLock()
    private var bindings = DesktopShortcutBindings.defaults
    private var hotKey = WindowsHotKeySettings()

    func update(bindings: DesktopShortcutBindings, hotKey: WindowsHotKeySettings? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.bindings = bindings
        if let hotKey { self.hotKey = hotKey }
    }

    func snapshot() -> (DesktopShortcutBindings, WindowsHotKeySettings) {
        lock.lock()
        defer { lock.unlock() }
        return (bindings, hotKey)
    }
}

private final class WindowsActionShortcutStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func add(_ value: String) -> UnsafePointer<CChar>? {
        let bytes = Array(value.utf8CString)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        pointer.initialize(from: bytes, count: bytes.count)
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { pointers.forEach { $0.deallocate() } }
}

enum WindowsActionShortcuts {
    /// The sidebar's Ctrl+digit links run before in-window action shortcuts.
    static func sidebarOwner(
        _ action: DesktopShortcutAction, _ chord: DesktopShortcutWindowsChord
    ) -> String? {
        guard chord.modifiers == DesktopShortcutWindowsChord.control else { return nil }
        guard let link = DesktopSidebarShortcut.allCases.first(where: {
            chord.virtualKey == UInt32(0x30 + $0.digit)
        }) else { return nil }
        let run = WindowsActionShortcutRun(action)
        if run == .page(link.rawValue) { return nil }
        return "the sidebar's \(link.rawValue.replacingOccurrences(of: "-", with: " ").capitalized) shortcut"
    }

    static func dictationOwner(
        _ hotKey: WindowsHotKeySettings, _ chord: DesktopShortcutWindowsChord
    ) -> String? {
        let dictation = DesktopShortcutWindowsChord(modifiers: hotKey.modifiers, virtualKey: hotKey.virtualKey)
        return dictation == chord ? "the dictation shortcut" : nil
    }

    static func canBeGlobal(_ action: DesktopShortcutAction) -> Bool {
        WindowsActionShortcutRun(action) != .macOnly && action.supportsGlobalShortcut
    }

    static func note(_ action: DesktopShortcutAction, in bindings: DesktopShortcutBindings) -> String? {
        let run = WindowsActionShortcutRun(action)
        if run == .macOnly { return WindowsActionShortcutRun.macOnlyNote }
        let binding = bindings[action]
        guard binding.isEnabled else { return nil }
        guard let chord = bindings.editorRow(for: action).chord else {
            return binding.windowsUnsupportedReason.map { "\($0) It stays saved for your Mac." }
        }
        if binding.isGlobal && canBeGlobal(action) { return nil }
        guard let owner = sidebarOwner(action, chord) else { return nil }
        return "The\(owner.dropFirst(3)) also uses \(chord.displayName) and runs first."
    }

    /// Keeps the dialog's status line to a few lines.
    static func summary(_ warnings: [String], limit: Int = 3) -> String {
        guard warnings.count > limit else { return warnings.joined(separator: "\n") }
        return (warnings.prefix(limit) + ["and \(warnings.count - limit) more."]).joined(separator: "\n")
    }
}

extension WindowsNative {
    /// Reads the saved action shortcuts and sends them to the window, falling
    /// back to the defaults when a hand-edited value cannot be shown.
    @discardableResult
    static func configureActionShortcuts(_ holder: WindowsEventContext) async -> Bool {
        let bindings = await holder.controller.shortcutBindings
        let hotKey = await holder.controller.hotKeySettings()
        let context = Unmanaged.passUnretained(holder).toOpaque()
        WindowsActionShortcutState.shared.update(bindings: bindings, hotKey: hotKey)
        if applyActionShortcuts(bindings, context: context) { return true }
        WindowsActionShortcutState.shared.update(bindings: .defaults)
        return applyActionShortcuts(.defaults, context: context)
    }

    private static func actionShortcutRow(
        _ action: DesktopShortcutAction, _ bindings: DesktopShortcutBindings,
        strings: WindowsActionShortcutStrings, note: Bool
    ) -> JSTIActionShortcut {
        let run = WindowsActionShortcutRun(action)
        let row = bindings.editorRow(for: action)
        let note = note ? WindowsActionShortcuts.note(action, in: bindings) : nil
        return JSTIActionShortcut(
            identifier: strings.add(action.rawValue), title: strings.add(action.displayName),
            note: note.flatMap { strings.add($0) }, page: strings.add(run.page), run: run.code,
            modifiers: row.chord?.modifiers ?? 0, virtual_key: row.chord?.virtualKey ?? 0,
            enabled: row.isEnabled ? 1 : 0, global: row.isGlobal ? 1 : 0,
            can_be_global: WindowsActionShortcuts.canBeGlobal(action) ? 1 : 0
        )
    }

    static func applyActionShortcuts(_ bindings: DesktopShortcutBindings, context: UnsafeMutableRawPointer) -> Bool {
        let strings = WindowsActionShortcutStrings()
        let actions = DesktopShortcutAction.allCases
        let presets = DesktopShortcutPreset.allCases
        let rows = actions.map { actionShortcutRow($0, bindings, strings: strings, note: true) }
        let presetRows = presets.flatMap { preset in
            let bindings = DesktopShortcutBindings(preset: preset)
            return actions.map { actionShortcutRow($0, bindings, strings: strings, note: false) }
        }
        let names = presets.map { strings.add($0.displayName) }
        return withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer { rows in
                presetRows.withUnsafeBufferPointer { presetRows in
                    names.withUnsafeBufferPointer { names in
                        jsti_window_set_action_shortcuts(
                            rows.baseAddress, rows.count, names.baseAddress, presetRows.baseAddress, presets.count,
                            actionShortcutsCheck, actionShortcutsRefresh, context
                        ) == 0
                    }
                }
            }
        }
    }
}

/// The native dialog's check and save, on the UI thread. The rows are checked
/// against the last configured bindings; an accepted save joins the settings
/// queue, and a failed write puts the saved shortcuts back.
func actionShortcutsCheck(
    _ rows: UnsafePointer<JSTIActionShortcut>?, _ count: Int, _ commit: Int32,
    _ message: UnsafeMutablePointer<CChar>?, _ capacity: Int, _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context, let rows else { return -1 }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let (base, hotKey) = WindowsActionShortcutState.shared.snapshot()
    var edited: [DesktopHostShortcutRow] = []
    for index in 0..<count {
        let row = rows[index]
        guard let identifier = row.identifier,
              let action = DesktopShortcutAction(rawValue: String(cString: identifier)) else { continue }
        let chord = row.virtual_key == 0
            ? nil : DesktopShortcutWindowsChord(modifiers: row.modifiers, virtualKey: row.virtual_key)
        edited.append(DesktopHostShortcutRow(
            action: action, chord: chord, isEnabled: row.enabled != 0, isGlobal: row.global != 0
        ))
    }
    let edit = base.editing(
        edited, runnable: WindowsActionShortcutRun.runnable,
        blocking: { _, chord in WindowsActionShortcuts.dictationOwner(hotKey, chord) },
        warning: { action, chord in
            let global = edited.first { $0.action == action }?.isGlobal == true
            return global && WindowsActionShortcuts.canBeGlobal(action)
                ? nil : WindowsActionShortcuts.sidebarOwner(action, chord)
        }
    )
    switch edit {
    case .refused(let reason):
        copyActionShortcutMessage(reason, into: message, capacity: capacity)
        return -1
    case .accepted(let bindings, let warnings):
        copyActionShortcutMessage(WindowsActionShortcuts.summary(warnings), into: message, capacity: capacity)
        guard commit == 1 else { return 0 }
        WindowsActionShortcutState.shared.update(bindings: bindings)
        holder.enqueueSettings {
            do {
                try await holder.controller.saveShortcutBindings(bindings)
            } catch {
                WindowsNative.update(
                    "Action shortcuts could not be saved, so the previous ones are back: \(error.localizedDescription)"
                )
            }
            if !(await WindowsNative.configureActionShortcuts(holder)) {
                WindowsNative.update("The saved action shortcuts could not be shown. Reopen Action shortcuts.")
            }
        }
        return 0
    }
}

/// An imported configuration may have replaced the bindings.
func actionShortcutsRefresh(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    holder.enqueueSettings { _ = await WindowsNative.configureActionShortcuts(holder) }
}

/// Copies whole UTF-8 scalars only, so a shortened message is still valid text.
private func copyActionShortcutMessage(_ text: String, into buffer: UnsafeMutablePointer<CChar>?, capacity: Int) {
    guard let buffer, capacity > 0 else { return }
    var bytes: [UInt8] = []
    for scalar in text.unicodeScalars {
        let encoded = Array(String(scalar).utf8)
        guard bytes.count + encoded.count < capacity else { break }
        bytes += encoded
    }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
}
