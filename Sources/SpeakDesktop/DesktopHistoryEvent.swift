import Foundation

/// A History pane event, submitted on the UI thread in the order the user
/// made it. Selection and version choose what is displayed; the others act on
/// audio and carry the record that was selected when they were clicked.
///
/// Hosts perform these through one `DesktopEventDispatcher` using `coalesce`,
/// so a click on a newly selected row reaches the host after that selection
/// instead of being refused for the previous row, and Stop can never be
/// overtaken by the Play or Read aloud it follows.
public enum DesktopHistoryEvent: Equatable, Sendable {
    case selection(String)
    case version(String, DesktopTranscriptVariant)
    case playPause(String)
    case stop
    /// Carries the transcript displayed at the click, which is spoken as is.
    case readAloud(String, text: String)

    /// Play/Pause and Read aloud clicks kept while the host catches up.
    /// Further clicks are ignored until it does, like clicks on a busy button;
    /// a new row and Stop are always kept, because they supersede them.
    public static let maximumPendingActions = 8

    /// The History ordering rule. Pending events keep submission order. Row
    /// and version changes still coalesce to the latest, as a burst of row
    /// changes always has. A new row also drops the clicks still aimed at the
    /// row it replaces, whose playback and Read aloud the host ends anyway,
    /// and Stop drops the clicks before it, whose playback it would end. At
    /// most one row, one version, one Stop and `maximumPendingActions` clicks
    /// are ever pending.
    public static let coalesce: DesktopEventDispatcher<DesktopHistoryEvent>.Coalescing = { pending, event in
        switch event.kind {
        case .row:
            pending.removeAll { $0.kind != .stop }
        case .version:
            pending.removeAll { $0.kind == .version }
        case .stop:
            pending.removeAll { $0.kind == .action || $0.kind == .stop }
        case .action:
            guard pending.filter({ $0.kind == .action }).count < maximumPendingActions else { return }
        }
        pending.append(event)
    }

    private enum Kind { case row, version, action, stop }

    private var kind: Kind {
        switch self {
        case .selection: return .row
        case .version: return .version
        case .playPause, .readAloud: return .action
        case .stop: return .stop
        }
    }
}
