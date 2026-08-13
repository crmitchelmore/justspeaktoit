import Foundation
import WidgetKit

/// One rendering of the watch-face state.
struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchComplicationSnapshot

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(
            score: snapshot.state.relevanceScore,
            duration: snapshot.state.relevanceDuration
        )
    }
}

/// Reads the state the watch app publishes into the App Group container.
///
/// The app reloads timelines on every state change, so the timeline itself is
/// a single entry. The periodic refresh keeps the face current when the app
/// writes the container but cannot reload (for example the recording
/// heartbeat), and it applies `settled()` again as time passes.
struct WatchComplicationProvider: TimelineProvider {
    /// How long an in-flight state may sit on the face before the widget
    /// re-reads the container unprompted.
    private static let inFlightRefresh: TimeInterval = 60
    private static let settledRefresh: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: Date(), snapshot: .idle)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
        let now = Date()
        completion(WatchComplicationEntry(date: now, snapshot: currentSnapshot(isPreview: context.isPreview, now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
        let now = Date()
        let snapshot = currentSnapshot(isPreview: context.isPreview, now: now)
        let refresh: TimeInterval = switch snapshot.state {
        case .recording, .sending: Self.inFlightRefresh
        case .idle, .inHistory, .failed: Self.settledRefresh
        }
        let entry = WatchComplicationEntry(date: now, snapshot: snapshot)
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(refresh))))
    }

    private func currentSnapshot(isPreview: Bool, now: Date) -> WatchComplicationSnapshot {
        guard !isPreview else {
            return WatchComplicationSnapshot(state: .idle, latestCaptureAt: now)
        }
        // `settled()` drops a recording state that a stopped app left behind.
        return WatchComplicationSnapshot.load().settled(now: now)
    }
}
