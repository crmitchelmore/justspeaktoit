import AppKit
import Foundation
import SpeakCore
import SpeakHotKeys

/// Manages global and local keyboard shortcuts for the application.
@MainActor
final class ShortcutManager: ObservableObject {
    @Published private(set) var bindings: [ShortcutAction: KeyBinding] = [:]
    @Published private(set) var conflicts: [ShortcutConflict] = []
    var migrationWarnings: [String] {
        carbonHotKeys.registrationConflicts.map { "\($0.action.displayName): \($0.description)" }
    }
    @Published private(set) var isRecordingShortcut: Bool = false
    @Published private(set) var recordingAction: ShortcutAction?
    @Published private(set) var recordingError: String?

    private lazy var carbonHotKeys = CarbonHotKeyRegistry { [weak self] action in
        self?.handleGlobalHotKey(action)
    }
    private var localMonitor: Any?
    private var recordingMonitor: Any?
    private var handlers: [ShortcutAction: () -> Void] = [:]
    private let permissionsManager: PermissionsManager

    private let defaultsKey = "customShortcutBindings"
    private let defaults: UserDefaults

    /// `defaults` is injectable so the stored-binding migration can be tested against a
    /// throwaway suite instead of the user's real preferences.
    init(permissionsManager: PermissionsManager, defaults: UserDefaults = .standard) {
        self.permissionsManager = permissionsManager
        self.defaults = defaults
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

    /// Registers a handler for a specific shortcut action. Actions the current
    /// distribution channel cannot support are ignored, so they can never fire.
    func register(action: ShortcutAction, handler: @escaping () -> Void) {
        guard action.isAvailable(in: .current) else { return }
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
        recordingError = nil

        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Ignore modifier-only presses
            if KeyCodeMapping.modifierKeyCodes.contains(event.keyCode) {
                return nil
            }

            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // Escape cancels without replacing the existing shortcut.
            if event.keyCode == 53, modifiers.isEmpty {
                self.stopRecording()
                return nil
            }

            guard KeyCodeMapping.isSupportedCustomHotKey(
                keyCode: event.keyCode,
                hasModifiers: !modifiers.isEmpty
            ) else {
                self.recordingError = KeyCodeMapping.unsupportedSingleKeyMessage
                return nil
            }

            let newBinding = KeyBinding(
                keyCode: event.keyCode,
                modifiers: modifiers,
                // Re-recording the keys must not silently reset a Global choice the user
                // already made either way.
                isGlobal: self.bindings[action]?.isGlobal ?? action.isGlobalByDefault,
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
        recordingError = nil
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
        localMonitor != nil || carbonHotKeys.isInstalled
    }

    private func handleKeyEvent(_ event: NSEvent, isGlobal: Bool) -> Bool {
        guard !isRecordingShortcut else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Don't steal normal typing (e.g. Space / Escape) from text inputs.
        if isTextInputFocused(), modifiers.isEmpty {
            return false
        }

        for (action, binding) in bindings {
            guard binding.isEnabled, action.isAvailable(in: .current) else { continue }
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
        carbonHotKeys.register(bindings)
        detectConflicts()
    }

    private func unregisterCarbonHotkeys() {
        carbonHotKeys.unregister()
    }

    private func handleGlobalHotKey(_ action: ShortcutAction) {
        guard !isRecordingShortcut, action.isAvailable(in: .current) else { return }
        guard let binding = bindings[action], binding.isEnabled && binding.isGlobal else { return }
        handlers[action]?()
    }

    private func loadBindings() {
        if let data = defaults.data(forKey: defaultsKey),
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
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private func detectConflicts() {
        conflicts = ShortcutConflict.systemConflicts(in: bindings) + carbonHotKeys.registrationConflicts
    }
}

extension ShortcutManager {
    func reloadAfterMigration() {
        loadBindings()
        if isMonitoring {
            unregisterCarbonHotkeys()
            registerCarbonHotkeys()
        }
    }
}
