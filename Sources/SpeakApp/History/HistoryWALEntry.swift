import Foundation

/// WAL entry representing a pending history operation
struct WALEntry: Codable {
  enum Operation: String, Codable {
    case append
    case update
    case remove
    case removeAll
  }

  let id: UUID
  let operation: Operation
  let item: HistoryItem?
  let timestamp: Date

  init(operation: Operation, item: HistoryItem? = nil) {
    self.id = UUID()
    self.operation = operation
    self.item = item
    self.timestamp = Date()
  }
}

extension [WALEntry] {
  /// Applies the queued operations, in order, to an item list. Shared by WAL
  /// replay and by the startup merge of mutations queued while storage was
  /// unavailable (issue #695). Appends are idempotent by item id.
  func applied(to items: [HistoryItem]) -> [HistoryItem] {
    var current = items
    for entry in self {
      switch entry.operation {
      case .append:
        if let item = entry.item, !current.contains(where: { $0.id == item.id }) {
          current.insert(item, at: 0)
        }
      case .update:
        if let item = entry.item, let index = current.firstIndex(where: { $0.id == item.id }) {
          current[index] = item
        }
      case .remove:
        if let item = entry.item {
          current.removeAll { $0.id == item.id }
        }
      case .removeAll:
        current.removeAll()
      }
    }
    return current
  }
}

/// Startup persistence state. `failed` means the on-disk history could not be
/// loaded; the last snapshot is left untouched and every operation that could
/// replace it is blocked until a retry succeeds (issue #695).
enum HistoryLoadState: Equatable {
  case loading
  case ready
  case failed(String)

  var isReady: Bool { self == .ready }
}
