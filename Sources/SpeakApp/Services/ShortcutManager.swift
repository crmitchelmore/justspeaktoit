import AppKit
import Carbon
import Foundation
import SpeakHotKeys

// swiftlint:disable file_length
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
    case openVoiceOutputSettings
    case openPronunciationSettings
    case openAPIKeysSettings
    case openKeyboardSettings
    case openPermissionsSettings
    case openAboutSettings
    case quickVoice1
    case quickVoice2
    case quickVoice3

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
        case .openVoiceOutputSettings: return "Open Voice Output Settings"
        case .openPronunciationSettings: return "Open Pronunciation Settings"
        case .openAPIKeysSettings: return "Open API Keys Settings"
        case .openKeyboardSettings: return "Open Keyboard Settings"
        case .openPermissionsSettings: return "Open Permissions Settings"
        case .openAboutSettings: return "Open About Settings"
        case .quickVoice1: return "Quick Switch Voice 1"
        case .quickVoice2: return "Quick Switch Voice 2"
        case .quickVoice3: return "Quick Switch Voice 3"
        }
    }

    var defaultKeyBinding: KeyBinding {
        switch self {
        case .openDashboard:
            return KeyBinding(keyCode: 2, modifiers: [.command], isGlobal: false)  // ⌘D
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
        case .openAboutSettings:
            return KeyBinding(keyCode: 25, modifiers: [.command], isGlobal: false)  // ⌘9
        case .quickVoice1:
            return KeyBinding(keyCode: 18, modifiers: [.command, .option], isGlobal: false)  // ⌘⌥1
        case .quickVoice2:
            return KeyBinding(keyCode: 19, modifiers: [.command, .option], isGlobal: false)  // ⌘⌥2
        case .quickVoice3:
            return KeyBinding(keyCode: 20, modifiers: [.command, .option], isGlobal: false)  // ⌘⌥3
        }
    }

    var legacyDefaultKeyBindings: [KeyBinding] {
        switch self {
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
            return [KeyBinding(keyCode: 28, modifiers: [.command, .option, .shift], isGlobal: false)]
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
        KeyCodeMapping.string(for: code)
    }
}

/// Detected conflict with system or other app shortcuts.
struct ShortcutConflict {
    let action: ShortcutAction
    let conflictSource: String
    let description: String
}

private struct SystemShortcut {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let description: String
}

/// Manages global and local keyboard shortcuts for the application.
@MainActor
// swiftlint:disable:next type_body_length
final class ShortcutManager: ObservableObject {
    @Published private(set) var bindings: [ShortcutAction: KeyBinding] = [:]
    @Published private(set) var conflicts: [ShortcutConflict] = []
    @Published private(set) var isRecordingShortcut: Bool = false
    @Published private(set) var recordingAction: ShortcutAction?

    private var carbonHotKeys: [UInt32: EventHotKeyRef] = [:]
    private var carbonHotKeyActions: [UInt32: ShortcutAction] = [:]
    private var carbonEventHandler: EventHandlerRef?
    private var localMonitor: Any?
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

        registerCarbonHotkeys()
    }

    /// Stops monitoring for keyboard shortcuts.
    func stopMonitoring() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
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
        if isMonitoring {
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
        detectConflicts()
        if isMonitoring {
            unregisterCarbonHotkeys()
            registerCarbonHotkeys()
        }
    }

    /// Toggles whether a shortcut is global.
    func setGlobal(_ isGlobal: Bool, for action: ShortcutAction) {
        guard var binding = bindings[action] else { return }
        binding.isGlobal = isGlobal
        bindings[action] = binding
        saveBindings()

        if isMonitoring {
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

        if isMonitoring {
            unregisterCarbonHotkeys()
            registerCarbonHotkeys()
        }
    }

    /// Starts recording a new shortcut for an action.
    func startRecording(for action: ShortcutAction) {
        stopRecording()
        isRecordingShortcut = true
        recordingAction = action

        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Ignore modifier-only presses
            if KeyCodeMapping.modifierKeyCodes.contains(event.keyCode) {
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

    private var isMonitoring: Bool {
        localMonitor != nil || carbonEventHandler != nil
    }

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
        installCarbonEventHandler()
        for (action, binding) in bindings {
            guard binding.isEnabled && binding.isGlobal else { continue }

            var hotKeyRef: EventHotKeyRef?
            let carbonModifiers = carbonModifierFlags(from: binding.modifiers)
            let carbonID = Self.carbonHotKeyID(for: action)
            let hotKeyID = EventHotKeyID(
                signature: 0x5350_4B00,
                id: carbonID
            )

            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                carbonModifiers,
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let ref = hotKeyRef {
                carbonHotKeys[carbonID] = ref
                carbonHotKeyActions[carbonID] = action
            }
        }
    }

    private func unregisterCarbonHotkeys() {
        for (_, hotKeyRef) in carbonHotKeys {
            UnregisterEventHotKey(hotKeyRef)
        }
        carbonHotKeys.removeAll()
        carbonHotKeyActions.removeAll()
        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
            carbonEventHandler = nil
        }
    }

    private func installCarbonEventHandler() {
        guard carbonEventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleCarbonHotKeyEvent(event)
            },
            1,
            &eventType,
            selfPtr,
            &carbonEventHandler
        )

        if status != noErr {
            carbonEventHandler = nil
        }
    }

    private nonisolated func handleCarbonHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return OSStatus(eventNotHandledErr) }
        guard hotKeyID.signature == 0x5350_4B00 else { return OSStatus(eventNotHandledErr) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isRecordingShortcut else { return }
            guard let action = self.carbonHotKeyActions[hotKeyID.id] else { return }
            guard let binding = self.bindings[action], binding.isEnabled && binding.isGlobal else { return }
            self.handlers[action]?()
        }

        return noErr
    }

    private static func carbonHotKeyID(for action: ShortcutAction) -> UInt32 {
        UInt32(ShortcutAction.allCases.firstIndex(of: action) ?? 0) + 1
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
            let decoded = try? JSONDecoder().decode([ShortcutAction: KeyBinding].self, from: data) {
            bindings = decoded
            var changedDefaults = false
            for action in ShortcutAction.allCases {
                if let binding = bindings[action] {
                    if action.legacyDefaultKeyBindings.contains(binding) {
                        bindings[action] = action.defaultKeyBinding
                        changedDefaults = true
                    }
                } else {
                    bindings[action] = action.defaultKeyBinding
                    changedDefaults = true
                }
            }
            if changedDefaults {
                saveBindings()
            }
            detectConflicts()
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
        let systemShortcuts: [SystemShortcut] = [
            SystemShortcut(keyCode: 1, modifiers: [.command], description: "Save (System)"),
            SystemShortcut(keyCode: 9, modifiers: [.command], description: "Paste (System)"),
            SystemShortcut(keyCode: 8, modifiers: [.command], description: "Copy (System)"),
            SystemShortcut(keyCode: 0, modifiers: [.command], description: "Select All (System)"),
            SystemShortcut(keyCode: 6, modifiers: [.command], description: "Undo (System)"),
            SystemShortcut(keyCode: 4, modifiers: [.command], description: "Hide App (System)"),
            SystemShortcut(keyCode: 12, modifiers: [.command], description: "Quit (System)"),
            SystemShortcut(keyCode: 13, modifiers: [.command], description: "Close Window (System)"),
            SystemShortcut(keyCode: 45, modifiers: [.command], description: "Minimize (System)")
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
