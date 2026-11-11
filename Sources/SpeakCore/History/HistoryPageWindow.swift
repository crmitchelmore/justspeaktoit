import Foundation

/// How many History rows a list builds. Search and filters always run over the
/// whole history first; the window only limits how many of the matching rows
/// are rendered, growing one page at a time as the list scrolls to its end, so
/// a long history never builds every row at once.
public struct HistoryPageWindow: Equatable, Sendable {
    public static let defaultPageSize = 100

    public let pageSize: Int
    public private(set) var limit: Int

    public init(pageSize: Int = HistoryPageWindow.defaultPageSize) {
        self.pageSize = max(1, pageSize)
        limit = self.pageSize
    }

    /// Rows to render out of `total` matching rows.
    public func visibleCount(of total: Int) -> Int {
        min(limit, max(0, total))
    }

    public func hasMore(total: Int) -> Bool {
        limit < total
    }

    /// Grows the window by one page. Returns false when every row is already shown.
    @discardableResult
    public mutating func loadMore(total: Int) -> Bool {
        guard hasMore(total: total) else { return false }
        limit += pageSize
        return true
    }

    /// Back to the first page, for a new search or filter.
    public mutating func reset() {
        limit = pageSize
    }

    /// Grows the window, in whole pages, until it includes the row at `index`,
    /// so a selected row is never hidden by paging alone.
    public mutating func reveal(index: Int) {
        guard index >= limit else { return }
        limit = (index / pageSize + 1) * pageSize
    }
}
