import Foundation
import SpeakCore

extension CommandPaletteHistoryItem {
    /// A History record as the command palette lists it: its transcript
    /// preview, then when it was recorded and with which models.
    public init(_ record: DesktopRecordingStore.Record, searchText: String) {
        let summary = DesktopHistoryRowSummary(record)
        self.init(
            id: record.id.uuidString,
            title: summary.preview,
            detail: "\(summary.created) · \(summary.models)",
            searchText: searchText
        )
    }

    /// The newest `limit` records, newest first, for the palette's snapshot.
    public static func newest(
        _ records: some Collection<DesktopRecordingStore.Record>, limit: Int = CommandPaletteHistorySnapshot.limit,
        searchText: (DesktopRecordingStore.Record) -> String = DesktopHistorySearch.searchText(for:)
    ) -> [CommandPaletteHistoryItem] {
        DesktopHistorySearch.ordered(Array(records)).prefix(limit).map { Self($0, searchText: searchText($0)) }
    }
}
