import Foundation
import SpeakCore

extension DesktopMigrationRestore.Preview {
    /// Plain-language confirmation text. It never includes transcript text,
    /// profile contents, identifiers or credential values.
    public var text: String {
        var lines = ["Review this restore. Nothing has been written yet.", ""]
        for row in self.rows {
            lines.append(contentsOf: Self.describe(row))
        }
        if self.rows.isEmpty {
            lines.append("This backup has no History text or dictation profiles this device can restore.")
        }
        if !self.notApplied.isEmpty {
            lines.append("")
            lines.append("Kept in the backup but not applied on this device:")
            for category in self.notApplied {
                lines.append("• " + Self.notAppliedReason(category))
            }
        }
        let skipped = self.skipped + (self.noticeCount > 0
            ? ["The backup reported \(self.noticeCount) item(s) it could not include or read."] : [])
        if !skipped.isEmpty {
            lines.append("")
            lines.append("Not restored:")
            lines.append(contentsOf: skipped.map { "• " + $0 })
        }
        lines.append("")
        lines.append(self.offersReplace
            ? "Merge keeps this device's version of every conflicting profile. "
                + "Replace makes your profiles match the backup. History always merges."
            : "Restore merges the backup into this device. Existing items are kept.")
        lines.append("If anything fails, every change is put back.")
        return lines.joined(separator: "\n")
    }

    private static func describe(_ row: DesktopMigrationRestore.Row) -> [String] {
        let title = row.category.title
        guard let merge = row.merge else {
            return ["\(title): could not be read, so existing items are kept."]
        }
        var lines: [String] = []
        if row.category == .history {
            lines.append("\(title) (always merged): " + Self.counts(merge) + ".")
            lines.append("  A backup version that differs is added as a separate entry; nothing is removed.")
        } else if let replace = row.replace, replace != merge {
            lines.append("\(title):")
            lines.append("  Merge: " + Self.counts(merge) + ".")
            lines.append("  Replace: " + Self.counts(replace) + ".")
        } else {
            lines.append("\(title): " + Self.counts(merge) + ".")
        }
        if row.conflicts > 0 {
            lines.append("  \(row.conflicts) conflicting item(s): Merge keeps this device's version; "
                + "Replace uses the backup's.")
        }
        if row.invalid > 0 {
            lines.append("  \(row.invalid) backup item(s) could not be used and are skipped.")
        }
        if row.preservedOnReplace {
            lines.append("  Some items were damaged, so Replace keeps every existing item.")
        }
        return lines
    }

    private static func counts(_ changes: DesktopMigrationRestore.Changes) -> String {
        var parts = ["\(changes.added) new", "\(changes.updated) updated"]
        if changes.removed > 0 { parts.append("\(changes.removed) removed") }
        if changes.reordered { parts.append("order changed to match the backup") }
        parts.append("\(changes.existing) on this device before, \(changes.retained) after")
        return parts.joined(separator: ", ")
    }

    private static func notAppliedReason(_ category: DataMigrationCategory) -> String {
        switch category {
        case .credentials:
            return category.title + ": never imported automatically; values are not shown."
        case .recordings:
            return category.title + " (audio): restore audio on a Mac for now."
        case .settings:
            return category.title + ": device settings, shortcuts and microphones stay as they are."
        default:
            return category.title + ": not restored on this device yet."
        }
    }
}
