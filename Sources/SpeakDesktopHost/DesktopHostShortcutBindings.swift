import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostPlatform {
    /// Configuration keys whose shortcut bindings this host applies. Hosts
    /// without action shortcuts keep the Mac bindings as preserved entries.
    package static var shortcutConfigurationKeys: Set<String> { [] }
}

extension DesktopHostController {
    /// The Mac-compatible action shortcuts stored with the portable settings.
    /// Missing or malformed values fall back to the shared defaults.
    package var shortcutBindings: DesktopShortcutBindings {
        DesktopShortcutBindings(configuration: settings.configuration)
    }

    /// Persists every binding under the Mac `customShortcutBindings` key, so
    /// export, import and the Mac app read the same value. Bindings for
    /// actions this host cannot run are kept unchanged.
    package func saveShortcutBindings(_ bindings: DesktopShortcutBindings) throws {
        guard !closed else { throw DesktopHostError(message: "The app is closing.") }
        var changed = settings
        let base = try settings.configuration ?? DesktopConfiguration()
        changed.configuration = try base.replacingShortcutBindings(bindings)
        try effects.writeSettings(JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json"))
        settings = changed
    }
}

/// One row of a desktop shortcut editor: the combination in Ctrl/Alt/Shift
/// terms (nil when not set) and the two switches the editor changes.
package struct DesktopHostShortcutRow: Equatable, Sendable {
    package let action: DesktopShortcutAction
    package let chord: DesktopShortcutWindowsChord?
    package let isEnabled: Bool
    package let isGlobal: Bool

    package init(action: DesktopShortcutAction, chord: DesktopShortcutWindowsChord?, isEnabled: Bool, isGlobal: Bool) {
        self.action = action
        self.chord = chord
        self.isEnabled = isEnabled
        self.isGlobal = isGlobal
    }
}

package enum DesktopHostShortcutEdit: Equatable, Sendable {
    case accepted(DesktopShortcutBindings, warnings: [String])
    case refused(String)
}

extension DesktopShortcutBindings {
    /// The editor row for an action. A disabled binding of key code 0 with no
    /// modifiers is how the Mac stores "not set".
    package func editorRow(for action: DesktopShortcutAction) -> DesktopHostShortcutRow {
        let binding = self[action]
        let unset = binding.keyCode == 0 && binding.modifiers.isEmpty && !binding.isEnabled
        return DesktopHostShortcutRow(
            action: action, chord: unset ? nil : binding.windowsChord,
            isEnabled: binding.isEnabled, isGlobal: binding.isGlobal
        )
    }

    /// Applies an editor's rows. A row whose combination is unchanged keeps the
    /// stored Mac binding, so an Fn or Mac Control combination the editor cannot
    /// show survives a change to its switches. `blocking` names an owner that
    /// refuses an enabled combination for a runnable action, such as the
    /// separate dictation shortcut; `warning` names one that only warns, such
    /// as window navigation. Duplicates refuse only when an edited row is
    /// involved, so an imported duplicate never blocks unrelated changes, and
    /// warnings are reported only for edited rows.
    package func editing( // swiftlint:disable:this cyclomatic_complexity function_body_length
        _ rows: [DesktopHostShortcutRow],
        runnable: Set<DesktopShortcutAction>,
        blocking: (DesktopShortcutAction, DesktopShortcutWindowsChord) -> String? = { _, _ in nil },
        warning: (DesktopShortcutAction, DesktopShortcutWindowsChord) -> String? = { _, _ in nil }
    ) -> DesktopHostShortcutEdit {
        var edited = self
        var changed: Set<DesktopShortcutAction> = []
        for row in rows {
            let original = self[row.action]
            if row.chord == editorRow(for: row.action).chord {
                var binding = original
                binding.isEnabled = row.isEnabled
                binding.isGlobal = row.isGlobal
                if binding.isEnabled != original.isEnabled { changed.insert(row.action) }
                edited[row.action] = binding
                continue
            }
            changed.insert(row.action)
            guard let chord = row.chord else {
                edited[row.action] = DesktopShortcutBinding(
                    keyCode: 0, modifiers: [], isGlobal: row.isGlobal, isEnabled: false
                )
                continue
            }
            guard let binding = DesktopShortcutBinding(windows: chord, isGlobal: row.isGlobal, isEnabled: row.isEnabled)
            else {
                return .refused(
                    "\(row.action.displayName): \(chord.displayName) has no Mac equivalent, so it cannot be saved."
                )
            }
            guard DesktopShortcutKey.isRecordable(macKeyCode: binding.keyCode, hasModifiers: !binding.modifiers.isEmpty)
            else {
                return .refused(
                    "\(row.action.displayName): use Ctrl, Alt or Shift with \(chord.displayName). "
                        + "F13-F20 and Insert can be used alone."
                )
            }
            edited[row.action] = binding
        }
        var warnings: [String] = []
        for action in DesktopShortcutAction.allCases where runnable.contains(action) {
            let binding = edited[action]
            guard binding.isEnabled, let chord = edited.editorRow(for: action).chord else { continue }
            if let owner = blocking(action, chord) {
                return .refused("\(action.displayName) uses \(chord.displayName), which \(owner) already uses.")
            }
            if changed.contains(action), let owner = warning(action, chord) {
                warnings.append("\(action.displayName) uses \(chord.displayName), which \(owner) handles first.")
            }
        }
        let conflicts = edited.conflicts()
        for conflict in conflicts {
            guard case .duplicate(let owner) = conflict.kind else { continue }
            if changed.contains(conflict.action) || changed.contains(owner) { return .refused(conflict.message) }
        }
        let reserved = conflicts.filter { !$0.isBlocking && changed.contains($0.action) }.map(\.message)
        return .accepted(edited, warnings: reserved + warnings)
    }
}
