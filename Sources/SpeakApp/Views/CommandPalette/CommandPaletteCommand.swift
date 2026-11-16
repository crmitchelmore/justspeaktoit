import SpeakCore

/// The Mac's name for the shared palette action. The catalogue and ranking live
/// in SpeakCore (`CommandPaletteAction`, `CommandPaletteSearch`) so Windows and
/// Linux search the same actions the same way.
typealias CommandPaletteCommand = CommandPaletteAction

extension CommandPaletteAction {
    /// The Mac shortcut the command runs and shows beside its row, if it has one.
    var shortcutAction: ShortcutAction? {
        shortcut.flatMap { ShortcutAction(rawValue: $0.rawValue) }
    }

    /// Commands in display order that `channel` can run.
    static func all(in channel: DistributionChannel = .current) -> [CommandPaletteCommand] {
        catalogue.filter { command in
            guard command.shortcut != nil else { return true }
            return command.shortcutAction?.isAvailable(in: channel) ?? false
        }
    }
}
