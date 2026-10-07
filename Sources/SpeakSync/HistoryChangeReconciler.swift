import Foundation

/// Keeps only the final event for each record while preserving the order of
/// those final events. This makes duplicate changes and tombstones within one
/// CloudKit page deterministic; `HistorySyncCoordinator` applies the pages
/// themselves in feed order.
enum HistoryChangeReconciler {
    static func coalesced(_ changes: [HistoryRemoteChange]) -> [HistoryRemoteChange] {
        var latestByID: [UUID: (offset: Int, change: HistoryRemoteChange)] = [:]
        for (offset, change) in changes.enumerated() {
            latestByID[change.id] = (offset, change)
        }
        return latestByID.values
            .sorted { $0.offset < $1.offset }
            .map(\.change)
    }
}
