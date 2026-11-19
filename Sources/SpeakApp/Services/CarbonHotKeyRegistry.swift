import AppKit
import Carbon
import Foundation

/// Owns the global (Carbon) registrations for the enabled global bindings and
/// routes a pressed hot key back to its action on the main queue.
@MainActor
final class CarbonHotKeyRegistry {
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyActions: [UInt32: ShortcutAction] = [:]
    /// Carbon's view of this registry. Retiring it (or this registry) closes
    /// delivery before the Carbon handler is removed.
    private var eventHandler: CarbonHotKeyHandler?
    private let onHotKey: (ShortcutAction) -> Void

    /// Bindings macOS refused during the last `register(_:)`.
    private(set) var registrationConflicts: [ShortcutConflict] = []

    init(onHotKey: @escaping (ShortcutAction) -> Void) {
        self.onHotKey = onHotKey
    }

    var isInstalled: Bool { eventHandler != nil }

    func register(_ bindings: [ShortcutAction: KeyBinding]) {
        registrationConflicts.removeAll()
        installEventHandler()
        for (action, binding) in bindings {
            guard binding.isEnabled && binding.isGlobal, action.isAvailable(in: .current) else { continue }

            var hotKeyRef: EventHotKeyRef?
            let carbonModifiers = Self.carbonModifierFlags(from: binding.modifiers)
            let carbonID = Self.carbonHotKeyID(for: action)
            let hotKeyID = EventHotKeyID(
                signature: CarbonHotKeyHandler.signature,
                id: carbonID
            )

            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let ref = hotKeyRef {
                hotKeys[carbonID] = ref
                hotKeyActions[carbonID] = action
            } else {
                registrationConflicts.append(ShortcutConflict(
                    action: action, conflictSource: "macOS registration",
                    description: "Shortcut unavailable (\(status)). Choose another binding in Keyboard settings."
                ))
            }
        }
    }

    func unregister() {
        for (_, hotKeyRef) in hotKeys {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeys.removeAll()
        hotKeyActions.removeAll()
        eventHandler?.remove()
        eventHandler = nil
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        let handler = CarbonHotKeyHandler { [weak self] hotKeyID in
            DispatchQueue.main.async { [weak self] in
                self?.handleHotKey(hotKeyID)
            }
        }
        guard handler.install() == noErr else { return }
        eventHandler = handler
    }

    private func handleHotKey(_ hotKeyID: UInt32) {
        guard let action = hotKeyActions[hotKeyID] else { return }
        onHotKey(action)
    }

    private static func carbonHotKeyID(for action: ShortcutAction) -> UInt32 {
        UInt32(ShortcutAction.allCases.firstIndex(of: action) ?? 0) + 1
    }

    private static func carbonModifierFlags(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        return carbonModifiers
    }
}
