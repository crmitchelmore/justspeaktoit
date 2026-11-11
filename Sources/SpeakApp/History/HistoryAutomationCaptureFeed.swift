import Foundation

/// Tells automation clients when a local capture's History entry is final.
///
/// The append revision is an in-memory cursor reset with this History/server
/// lifetime, never a persisted sync cursor.
@MainActor
final class HistoryAutomationCaptureFeed {
  struct Completion {
    let captureID: UUID
    let revision: UInt64
    let item: HistoryItem?
  }

  private(set) var appendRevision: UInt64 = 0
  private var observers: [UUID: (Completion) -> Void] = [:]

  func recordAppend() {
    appendRevision &+= 1
  }

  func observe(_ observer: @escaping (Completion) -> Void) -> UUID {
    let token = UUID()
    observers[token] = observer
    return token
  }

  func removeObserver(_ token: UUID) {
    observers.removeValue(forKey: token)
  }

  func finish(captureID: UUID, item: HistoryItem?) {
    let event = Completion(captureID: captureID, revision: appendRevision, item: item)
    for observer in Array(observers.values) { observer(event) }
  }
}
