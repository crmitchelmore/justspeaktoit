import AppKit
import Carbon
import Foundation

/// Represents a keyboard shortcut action that can be triggered globally or locally.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case startStopRecording
    case speakSelectedText
    case speakClipboard
    case pauseResumeTTS
    case stopTTS
    case openSettings
    case showHistory
    case quickVoice1
    case quickVoice2
    case quickVoice3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .startStopRecording: return "Start/Stop Recording"
        case .speakSelectedText: return "Speak Selected Text"
        case .speakClipboard: return "Speak Clipboard Content"
        case .pauseResumeTTS: return "Pause/Resume TTS"
        case .stopTTS: return "Stop TTS"
        case .openSettings: return "Open Settings"
        case .showHistory: return "Show History"
        case .quickVoice1: return "Quick Switch Voice 1"
        case .quickVoice2: return "Quick Switch Voice 2"
        case .quickVoice3: return "Quick Switch Voice 3"
        }
    }

    var defaultKeyBinding: KeyBinding {
        switch self {
        case .startStopRecording:
            return KeyBinding(keyCode: 1, modifiers: [.command, .shift])  // ⌘+Shift+S
        case .speakSelectedText:
            return KeyBinding(keyCode: 17, modifiers: [.command, .shift])  // ⌘+Shift+T
        case .speakClipboard:
            return KeyBinding(keyCode: 9, modifiers: [.command, .shift])  // ⌘+Shift+V
        case .pauseResumeTTS:
            return KeyBinding(keyCode: 49, modifiers: [], isGlobal: false)  // Space
        case .stopTTS:
            return KeyBinding(keyCode: 53, modifiers: [], isGlobal: false)  // Escape
        case .openSettings:
            return KeyBinding(keyCode: 43, modifiers: [.command], isGlobal: false)  // ⌘+,
        case .showHistory:
            return KeyBinding(keyCode: 4, modifiers: [.command], isGlobal: false)  // ⌘+H
        case .quickVoice1:
            return KeyBinding(keyCode: 18, modifiers: [.command], isGlobal: false)  // ⌘+1
        case .quickVoice2:
            return KeyBinding(keyCode: 19, modifiers: [.command], isGlobal: false)  // ⌘+2
        case .quickVoice3:
            return KeyBinding(keyCode: 20, modifiers: [.command], isGlobal: false)  // ⌘+3
        }
    }

    var isGlobalByDefault: Bool {
        switch self {
        case .startStopRecording, .speakSelectedText, .speakClipboard:
            return true
        default:
            return false
        }
    }
}

/// Represents a keyboard shortcut binding.
struct KeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var isGlobal: Bool
    var isEnabled: Bool

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isGlobal: Bool = true, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isGlobal = isGlobal
        self.isEnabled = isEnabled
    }

    // Custom Codable to handle NSEvent.ModifierFlags
    enum CodingKeys: String, CodingKey {
        case keyCode, modifiersRaw, isGlobal, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let rawModifiers = try container.decode(UInt.self, forKey: .modifiersRaw)
        modifiers = NSEvent.ModifierFlags(rawValue: rawModifiers)
        isGlobal = try container.decode(Bool.self, forKey: .isGlobal)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiersRaw)
        try container.encode(isGlobal, forKey: .isGlobal)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    private func keyCodeToString(_ code: UInt16) -> String {
        switch code {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "␣"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "PgDn"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "?"
        }
    }
}

/// Detected conflict with system or other app shortcuts.
struct ShortcutConflict {
    let action: ShortcutAction
    let conflictSource: String
    let description: String
}

/// Manages global and local keyboard shortcuts for the application.
@MainActor
final class ShortcutManager: ObservableObject {
    @Published private(set) var bindings: [ShortcutAction: KeyBinding] = [:]
    @Published private(set) var conflicts: [ShortcutConflict] = []
    @Published private(set) var isRecordingShortcut: Bool = false
    @Published private(set) var recordingAction: ShortcutAction?

    private var globalEventHandlers: [UInt32: EventHotKeyRef] = [:]
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var recordingMonitor: Any?
    private var handlers: [ShortcutAction: () -> Void] = [:]
    private let permissionsManager: PermissionsManager

    private let defaultsKey = "customShortcutBindings"

    init(permissionsManager: PermissionsManager) {
        self.permissionsManager = permissionsManager
        loadBindings()
    }

    /// Starts monitoring for keyboard shortcuts.
    func startMonitoring() {
        stopMonitoring()

        // Local monitor for app-focused shortcuts
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleKeyEvent(event, isGlobal: false) {
                return nil
            }
            return event
        }

        // Global monitor for system-wide shortcuts
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            _ = self.handleKeyEvent(event, isGlobal: true)
        }

        registerCarbonHotkeys()
    }

    /// Stops monitoring for keyboard shortcuts.
    func stopMonitoring() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        unregisterCarbonHotkeys()
    }

    /// Registers a handler for a specific shortcut action.
    func register(action: ShortcutAction, handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    /// Unregisters a handler for a specific action.
    func unregister(action: ShortcutAction) {
        handlers[action] = nil
    }

    /// Updates the key binding for an action.
    func setBinding(_ binding: KeyBinding, for action: ShortcutAction) {
        bindings[action] = binding
        saveBindings()
        detectConflicts()

        // Re-register global shortcuts if monitoring is active
        if globalMonitor != nil {
            unregisterCarbonHotkeys()
            registerCarbonHotkeys()
        }
    }

    /// Toggles whether a shortcut is enabled.
    func setEnabled(_ enabled: Bool, for action: ShortcutAction) {
        guard var binding = bindings[action] else { return }
        binding.isEnabled = enabled
        bindings[action] = binding
        saveBindings()
    }

    /// Toggles whether a shortcut is global.
    func setGlobal(_ isGlobal: Bool, for action: ShortcutAction) {
        guard var binding = bindings[action] else { return }
        binding.isGlobal = isGlobal
        bindings[action] = binding
        saveBindings()

        if globalMonitor != nil {
            unregisterCarbonHotkeys()
            registerCarbonHotkeys()
        }
    }

    /// Resets all bindings to defaults.
    func resetToDefaults() {
        bindings = [:]
        for action in ShortcutAction.allCases {
            bindings[action] = action.defaultKeyBinding
        }
        saveBindings()
        detectConflicts()

        if globalMonitor != nil {
            unregisterCarbonHotkeys()
            registerCarbonHotkeys()
        }
    }

    /// Starts recording a new shortcut for an action.
    func startRecording(for action: ShortcutAction) {
        isRecordingShortcut = true
        recordingAction = action

        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Ignore modifier-only presses
            if event.keyCode == 56 || event.keyCode == 54 || event.keyCode == 58 || event.keyCode == 55
                || event.keyCode == 59 || event.keyCode == 62 || event.keyCode == 60 || event.keyCode == 61
            {
                return nil
            }

            let newBinding = KeyBinding(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection([.command, .shift, .option, .control]),
                isGlobal: action.isGlobalByDefault,
                isEnabled: true
            )

            self.setBinding(newBinding, for: action)
            self.stopRecording()
            return nil
        }
    }

    /// Stops recording a shortcut.
    func stopRecording() {
        isRecordingShortcut = false
        recordingAction = nil
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMonitor = nil
        }
    }

    /// Gets the key binding for an action.
    func binding(for action: ShortcutAction) -> KeyBinding {
        bindings[action] ?? action.defaultKeyBinding
    }

    // MARK: - Private Methods

    private func handleKeyEvent(_ event: NSEvent, isGlobal: Bool) -> Bool {
        guard !isRecordingShortcut else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Don't steal normal typing (e.g. Space / Escape) from text inputs.
        if isTextInputFocused(), modifiers.isEmpty {
            return false
        }

        for (action, binding) in bindings {
            guard binding.isEnabled else { continue }
            guard binding.isGlobal == isGlobal || !isGlobal else { continue }

            if event.keyCode == binding.keyCode && modifiers == binding.modifiers {
                if let handler = handlers[action] {
                    handler()
                    return true
                }
            }
        }
        return false
    }

    private func isTextInputFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if responder is NSTextField { return true }
        return false
    }

    private func registerCarbonHotkeys() {
        for (action, binding) in bindings {
            guard binding.isEnabled && binding.isGlobal else { continue }

            var hotKeyRef: EventHotKeyRef?
            let carbonModifiers = carbonModifierFlags(from: binding.modifiers)
            let hotKeyID = EventHotKeyID(signature: 0x5350_4B00, id: UInt32(bitPattern: Int32(truncatingIfNeeded: action.hashValue)))  // "SPK" signature

            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                carbonModifiers,
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let ref = hotKeyRef {
                globalEventHandlers[UInt32(bitPattern: Int32(truncatingIfNeeded: action.hashValue))] = ref
            }
        }
    }

    private func unregisterCarbonHotkeys() {
        for (_, hotKeyRef) in globalEventHandlers {
            UnregisterEventHotKey(hotKeyRef)
        }
        globalEventHandlers.removeAll()
    }

    private func carbonModifierFlags(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        return carbonModifiers
    }

    private func loadBindings() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([ShortcutAction: KeyBinding].self, from: data)
        {
            bindings = decoded
        } else {
            resetToDefaults()
        }
    }

    private func saveBindings() {
        if let data = try? JSONEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func detectConflicts() {
        var newConflicts: [ShortcutConflict] = []

        // Check for common system shortcut conflicts
        let systemShortcuts: [(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, description: String)] = [
            (1, [.command], "Save (System)"),
            (9, [.command], "Paste (System)"),
            (8, [.command], "Copy (System)"),
            (0, [.command], "Select All (System)"),
            (6, [.command], "Undo (System)"),
            (4, [.command], "Hide App (System)"),
            (12, [.command], "Quit (System)"),
            (13, [.command], "Close Window (System)"),
            (45, [.command], "Minimize (System)"),
        ]

        for (action, binding) in bindings where binding.isEnabled {
            for system in systemShortcuts {
                if binding.keyCode == system.keyCode && binding.modifiers == system.modifiers {
                    newConflicts.append(
                        ShortcutConflict(
                            action: action,
                            conflictSource: "System",
                            description: "Conflicts with \(system.description)"
                        )
                    )
                }
            }
        }

        conflicts = newConflicts
    }
}
