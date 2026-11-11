import SpeakCore

/// Host capability filters the canonical catalogue; this is not a second action list.
package struct DesktopLinuxGlobalShortcutPlan: Sendable {
    package struct Entry: Equatable, Sendable {
        package let action: DesktopShortcutAction
        package let identifier: Int32
        package let chord: DesktopShortcutLinuxChord
    }

    package let entries: [Entry]
    package let refusals: [DesktopShortcutAction: String]

    package init(
        bindings: DesktopShortcutBindings,
        runnable: Set<DesktopShortcutAction>,
        dictation: DesktopShortcutLinuxChord
    ) {
        var entries: [Entry] = []
        var refusals: [DesktopShortcutAction: String] = [:]
        var occupied: [DesktopShortcutLinuxChord: DesktopShortcutAction] = [:]
        for (index, action) in DesktopShortcutAction.allCases.enumerated() {
            let binding = bindings[action]
            guard binding.isEnabled, binding.isGlobal else { continue }
            guard action.supportsGlobalShortcut, runnable.contains(action) else {
                refusals[action] = "This action is not available as a Linux global shortcut."
                continue
            }
            guard let chord = binding.linuxChord else {
                refusals[action] = "This Mac-specific combination stays saved, not registered."
                continue
            }
            guard Self.isSafe(chord) else {
                refusals[action] = "Add Ctrl or Alt, or use F13-F24, for an all-app shortcut."
                continue
            }
            if chord == dictation {
                refusals[action] = "The Linux dictation shortcut already uses this combination."
                continue
            }
            if let prior = occupied[chord] {
                refusals[action] = "\(prior.displayName) already uses this combination."
                continue
            }
            occupied[chord] = action
            entries.append(Entry(action: action, identifier: Int32(index), chord: chord))
        }
        self.entries = entries
        self.refusals = refusals
    }

    package static func isSafe(_ chord: DesktopShortcutLinuxChord) -> Bool {
        chord.modifiers & (DesktopShortcutLinuxChord.control | DesktopShortcutLinuxChord.alt) != 0
            || (0xFFCA...0xFFD5).contains(chord.keysym)
    }
}
