import AppKit
import Foundation

/// Detected conflict with system or other app shortcuts.
struct ShortcutConflict {
    let action: ShortcutAction
    let conflictSource: String
    let description: String

    /// Enabled bindings that shadow a common system shortcut.
    static func systemConflicts(in bindings: [ShortcutAction: KeyBinding]) -> [ShortcutConflict] {
        var newConflicts: [ShortcutConflict] = []
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
        return newConflicts
    }

    // Check for common system shortcut conflicts
    private static let systemShortcuts: [SystemShortcut] = [
        SystemShortcut(keyCode: 1, modifiers: [.command], description: "Save (System)"),
        SystemShortcut(
            keyCode: 1, modifiers: [.command, .shift], description: "Save As (System)"
        ),
        SystemShortcut(keyCode: 9, modifiers: [.command], description: "Paste (System)"),
        SystemShortcut(keyCode: 8, modifiers: [.command], description: "Copy (System)"),
        SystemShortcut(keyCode: 0, modifiers: [.command], description: "Select All (System)"),
        SystemShortcut(keyCode: 6, modifiers: [.command], description: "Undo (System)"),
        SystemShortcut(keyCode: 4, modifiers: [.command], description: "Hide App (System)"),
        SystemShortcut(keyCode: 12, modifiers: [.command], description: "Quit (System)"),
        SystemShortcut(keyCode: 13, modifiers: [.command], description: "Close Window (System)"),
        SystemShortcut(keyCode: 45, modifiers: [.command], description: "Minimize (System)")
    ]
}

private struct SystemShortcut {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let description: String
}
