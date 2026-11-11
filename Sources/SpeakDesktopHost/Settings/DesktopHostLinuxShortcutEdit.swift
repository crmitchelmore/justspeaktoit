import Foundation
import SpeakCore

package struct DesktopHostLinuxShortcutRow: Equatable, Sendable {
    package let action: DesktopShortcutAction
    package let chord: DesktopShortcutLinuxChord?
    package let isEnabled: Bool
    package let isGlobal: Bool
    package let replacesKey: Bool

    package init(action: DesktopShortcutAction, chord: DesktopShortcutLinuxChord?,
                 isEnabled: Bool, isGlobal: Bool, replacesKey: Bool) {
        self.action = action
        self.chord = chord
        self.isEnabled = isEnabled
        self.isGlobal = isGlobal
        self.replacesKey = replacesKey
    }
}

/// A complete native draft, not a patch against whichever settings happen to
/// exist when its asynchronous save is admitted.
package struct DesktopHostLinuxShortcutRequest: Sendable {
    package let revision: UUID
    package let request: UUID
    package let rows: [DesktopHostLinuxShortcutRow]

    package init(wire: String) throws {
        guard wire.utf8.count <= 32768 else { throw DesktopHostError(message: "The shortcut draft is too large.") }
        let lines = wire.components(separatedBy: "\n")
        let header = lines[0].components(separatedBy: "\t")
        guard header.count == 2, let revision = UUID(uuidString: header[0]),
              let request = UUID(uuidString: header[1]), lines.last == "",
              lines.count == DesktopShortcutAction.allCases.count + 2 else {
            throw DesktopHostError(message: "The shortcut draft has an invalid revision or row count.")
        }
        self.revision = revision
        self.request = request
        self.rows = try lines.dropFirst().dropLast().map { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 6, let identifier = fields[0].removingPercentEncoding,
                  let action = DesktopShortcutAction(rawValue: identifier),
                  let key = UInt32(fields[1]), let modifiers = UInt32(fields[2]), modifiers & ~13 == 0,
                  ["0", "1"].contains(fields[3]), ["0", "1"].contains(fields[4]),
                  ["0", "1"].contains(fields[5]), key != 0 || modifiers == 0 else {
                throw DesktopHostError(message: "A shortcut draft row is invalid.")
            }
            return DesktopHostLinuxShortcutRow(
                action: action, chord: key == 0 ? nil : .init(keysym: key, modifiers: modifiers),
                isEnabled: fields[3] == "1", isGlobal: fields[4] == "1", replacesKey: fields[5] == "1"
            )
        }
        guard Set(rows.map(\.action)) == Set(DesktopShortcutAction.allCases) else {
            throw DesktopHostError(message: "The shortcut draft duplicates or omits an action.")
        }
    }
}

extension DesktopShortcutBindings {
    package func editingLinux(
        _ rows: [DesktopHostLinuxShortcutRow], runnable: Set<DesktopShortcutAction>,
        blocking: (DesktopShortcutAction, DesktopShortcutLinuxChord) -> String? = { _, _ in nil },
        warning: (DesktopShortcutAction, DesktopShortcutLinuxChord) -> String? = { _, _ in nil }
    ) -> DesktopHostShortcutEdit {
        var base = self
        var converted: [DesktopHostShortcutRow] = []
        for row in rows {
            let original = self[row.action]
            if row.isEnabled && !row.replacesKey && original.keyCode == 0 &&
                original.modifiers.isEmpty && !original.isEnabled {
                return .refused("\(row.action.displayName): choose a key before enabling this shortcut.")
            }
            var chord = editorRow(for: row.action).chord
            if row.replacesKey {
                if let linux = row.chord {
                    guard let binding = DesktopShortcutBinding(
                        linux: linux, isGlobal: row.isGlobal, isEnabled: row.isEnabled
                    ), let mapped = binding.windowsChord else {
                        return .refused("\(row.action.displayName): this key has no portable Mac equivalent.")
                    }
                    chord = mapped
                } else {
                    base[row.action] = .init(keyCode: 0, modifiers: [], isGlobal: row.isGlobal, isEnabled: false)
                    chord = nil
                }
            }
            converted.append(.init(
                action: row.action, chord: chord, isEnabled: row.isEnabled && (chord != nil || !row.replacesKey),
                isGlobal: row.isGlobal
            ))
        }
        func linux(_ chord: DesktopShortcutWindowsChord) -> DesktopShortcutLinuxChord? {
            DesktopShortcutBinding(windows: chord, isGlobal: false, isEnabled: true)?.linuxChord
        }
        return base.editing(
            converted, runnable: runnable,
            blocking: { action, chord in linux(chord).flatMap { blocking(action, $0) } },
            warning: { action, chord in linux(chord).flatMap { warning(action, $0) } }
        )
    }
}

extension DesktopHostController {
    package func saveShortcutBindings(_ bindings: DesktopShortcutBindings, replacing expected: DesktopShortcutBindings)
        throws {
        guard shortcutBindings == expected else {
            throw DesktopHostError(message: "Saved shortcuts changed. Reopen the editor before saving this draft.")
        }
        try saveShortcutBindings(bindings)
    }
}
