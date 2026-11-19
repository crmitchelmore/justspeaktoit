import AppKit
import Foundation
import SpeakCore
import os.log

/// What `HistoryPersistence` needs from the history it stores.
@MainActor
protocol HistoryPersistenceHost: AnyObject {
  /// The complete history to write as the next snapshot.
  var persistenceSnapshot: [HistoryItem] { get }
  /// `false` while startup load has failed: nothing on disk may be replaced.
  var acceptsPersistenceWrites: Bool { get }
  var isMigratingHistory: Bool { get }
  func waitUntilLoaded() async
  func persistenceErrorDidChange(_ message: String?)
}

/// Owns the on-disk history: the write-ahead log, the pending-write queue,
/// periodic and termination flushes, and startup load.
@MainActor
final class HistoryPersistence: RepeatingTimerTarget {
  static let writeFailureMessage = "History could not be written to disk. It will be retried automatically."

  weak var host: HistoryPersistenceHost?

  let storageURL: URL
  private let encoder: JSONEncoder
  private let log = SpeakLogger.logger(category: "HistoryManager")
  private let walStore: HistoryWALStore

  /// Pending writes waiting to be flushed
  private(set) var pendingWrites: [WALEntry] = []

  /// Flag to track if we're currently flushing
  private(set) var isFlushing = false

  /// Timer for periodic flushing
  private var flushTimer: Timer?

  /// Observer for app termination notification
  private var terminationObserver: NSObjectProtocol?

  /// Configurable flush interval
  var flushInterval: TimeInterval {
    didSet {
      scheduleFlushTimer()
    }
  }

  /// Batch size threshold for triggering flush
  var batchSizeThreshold: Int

  init(storageURL: URL, walURL: URL, flushInterval: TimeInterval, batchSizeThreshold: Int) {
    self.storageURL = storageURL
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.flushInterval = flushInterval
    self.batchSizeThreshold = batchSizeThreshold
    self.walStore = HistoryWALStore(storageURL: storageURL, walURL: walURL)
    registerForTerminationNotification()
  }

  deinit {
    flushTimer?.invalidate()
    if let observer = terminationObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: - Termination Handling

  private func registerForTerminationNotification() {
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { @MainActor [weak self] _ in
      guard let self else { return }
      // Termination notifications run on main thread - call sync wrapper
      self.flushImmediatelySync()
    }
  }

  // MARK: - Flush Timer Management

  func scheduleFlushTimer() {
    flushTimer?.invalidate()
    // Use target-selector pattern to avoid Swift concurrency crashes during deallocation.
    // Block-based timers with [weak self] can crash in swift_getObjectType during executor
    // verification when the object is deallocating.
    // A direct target retains the owner forever, so deinit cannot invalidate it.
    flushTimer = WeakRepeatingTimerTarget.scheduledTimer(interval: flushInterval, target: self)
  }

  func repeatingTimerDidFire() {
    flushIfNeededSync()
  }

  // MARK: - WAL Operations (delegated to HistoryWALStore actor)

  /// Append an entry via the isolated WAL store so FileHandle work stays
  /// off the MainActor. `pendingWrites` remains MainActor-isolated for
  /// flush bookkeeping; the on-disk append is actor-isolated.
  func record(_ entry: WALEntry) async {
    pendingWrites.append(entry)
    // While startup load has failed, nothing may touch the history files: the
    // entry stays queued in memory and is written after a successful retry.
    guard host?.acceptsPersistenceWrites == true else { return }
    do {
      try await walStore.append(entry)
    } catch {
      // The mutation is not durable yet; it remains in pendingWrites so the
      // next flush retries it through the snapshot commit.
      host?.persistenceErrorDidChange(Self.writeFailureMessage)
      log.error("WAL append failed: \(error.localizedDescription, privacy: .public)")
    }
    if pendingWrites.count >= batchSizeThreshold {
      await flushIfNeeded()
    }
  }

  // MARK: - Load

  /// Loads the persisted history and replays the mutations queued while the
  /// store was unavailable on top of it (issue #695). On first startup the
  /// queue is empty and this is the identity.
  func load() async throws -> [HistoryItem] {
    // Replay is a single actor transaction; if there is no WAL, load the
    // snapshot through the same actor so all history file I/O stays ordered.
    let persisted: [HistoryItem]
    if let replayed = try await walStore.replayWAL() {
      persisted = replayed
    } else {
      persisted = try await walStore.loadSnapshot()
    }
    return pendingWrites.applied(to: persisted)
  }

  /// Makes the queued mutations durable once the store is reachable. They
  /// remain in `pendingWrites` either way; flush commits them.
  func persistQueuedWrites() async {
    for entry in pendingWrites {
      try? await walStore.append(entry)
    }
    if !pendingWrites.isEmpty {
      await flushIfNeeded()
    }
  }

  /// Replaces the on-disk history with an imported snapshot, discarding the
  /// pending writes it supersedes.
  func commitMigrationSnapshot(_ snapshot: [HistoryItem]) async throws {
    isFlushing = true
    defer { isFlushing = false }
    try await walStore.commitSnapshot(snapshot, flushing: pendingWrites)
    pendingWrites.removeAll()
  }

  // MARK: - Flush Operations

  private var canStartFlush: Bool {
    !pendingWrites.isEmpty && !isFlushing && host?.isMigratingHistory != true
  }

  /// Flush pending writes if there are any
  private func flushIfNeeded() async {
    guard canStartFlush else { return }
    await flushImmediately()
  }

  /// Sync wrapper for timer callback - timer already runs on main thread
  private func flushIfNeededSync() {
    guard canStartFlush else { return }
    Task { [weak self] in
      await self?.flushImmediately()
    }
  }

  /// Termination flush. Runs entirely on the main actor and writes inline.
  ///
  /// The previous shape — `Task.detached { await flushImmediately() }` plus
  /// `DispatchSemaphore.wait()` — deadlocked: `flushImmediately()` is main-actor
  /// isolated, so the detached task could never enter it while the main actor was
  /// parked on the semaphore. The app then exited five seconds later with the
  /// pending writes unflushed. Doing the encode + write synchronously here costs a
  /// short stall during `willTerminate`, but actually persists the data.
  func flushImmediatelySync() {
    // A failed startup load means the in-memory view does not contain the
    // persisted history; writing it here would replace a valid snapshot with
    // only the newest items (issue #695).
    guard let host, host.acceptsPersistenceWrites else { return }
    guard canStartFlush else { return }
    isFlushing = true
    defer { isFlushing = false }

    log.info("Flushing \(self.pendingWrites.count) pending writes to disk (termination)")

    let snapshot = host.persistenceSnapshot

    do {
      try Self.writeSnapshot(snapshot, to: storageURL, encoder: encoder)
      // Intentionally retain the WAL during termination. Replay is idempotent,
      // and an asynchronous actor cleanup is not guaranteed to run before exit.
      log.info("Termination flush complete")
    } catch {
      log.error("Failed to flush history: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Force immediate flush of all pending writes — now via isolated WAL store
  func flushImmediately() async {
    guard let host else { return }
    await host.waitUntilLoaded()
    // Never replace the on-disk snapshot from a state that failed to load it.
    guard host.acceptsPersistenceWrites else { return }
    guard !isFlushing, !host.isMigratingHistory else { return }
    isFlushing = true
    defer { isFlushing = false }
    guard !pendingWrites.isEmpty else { return }
    log.info("Flushing \(self.pendingWrites.count) pending writes to disk")
    let snapshot = host.persistenceSnapshot
    let flushedCount = pendingWrites.count
    let flushedEntries = Array(pendingWrites.prefix(flushedCount))
    do {
      try await walStore.commitSnapshot(snapshot, flushing: flushedEntries)
      // The WAL actor has already removed exactly these entries, so later
      // appends remain pending and durable.
      pendingWrites.removeFirst(min(flushedCount, pendingWrites.count))
      host.persistenceErrorDidChange(nil)
      log.info("Flush complete")
    } catch {
      host.persistenceErrorDidChange(Self.writeFailureMessage)
      log.error("Failed to flush history: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Encode + atomic write. Retained for termination path which must stay
  /// synchronous; the async path now uses `walStore.writeSnapshot`.
  private nonisolated static func writeSnapshot(
    _ items: [HistoryItem],
    to url: URL,
    encoder: JSONEncoder
  ) throws {
    let data = try encoder.encode(items)
    try data.write(to: url, options: [.atomic])
  }
}
