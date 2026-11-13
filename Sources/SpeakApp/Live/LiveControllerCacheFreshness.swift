import AppKit
import Foundation

struct LiveTranscriptionControllerReusePolicy {
  static let idleResetThreshold: TimeInterval = 10 * 60

  static func shouldResetControllers(
    invalidateBeforeNextStart: Bool,
    lastStopDate: Date?,
    now: Date
  ) -> Bool {
    guard !invalidateBeforeNextStart else { return true }
    guard let lastStopDate else { return false }
    return now.timeIntervalSince(lastStopDate) >= idleResetThreshold
  }
}

/// Decides when the cached live controllers must be rebuilt before the next
/// start: after a failed start, a sleep or wake, an explicit invalidation (for
/// example a removed API key) or ten idle minutes since the last stop. It owns
/// the sleep/wake observers, so their tokens live and die with this state.
@MainActor
final class LiveControllerCacheFreshness {
  private let nowProvider: () -> Date
  private(set) var isStale = false
  private var lastStopDate: Date?
  private var willSleepObserver: NSObjectProtocol?
  private var didWakeObserver: NSObjectProtocol?

  init(nowProvider: @escaping () -> Date) {
    self.nowProvider = nowProvider
    let notificationCenter = NSWorkspace.shared.notificationCenter
    willSleepObserver = notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.markStale()
      }
    }
    didWakeObserver = notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.markStale()
      }
    }
  }

  deinit {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    if let willSleepObserver {
      notificationCenter.removeObserver(willSleepObserver)
    }
    if let didWakeObserver {
      notificationCenter.removeObserver(didWakeObserver)
    }
  }

  var shouldResetBeforeStart: Bool {
    LiveTranscriptionControllerReusePolicy.shouldResetControllers(
      invalidateBeforeNextStart: isStale,
      lastStopDate: lastStopDate,
      now: nowProvider()
    )
  }

  func markStale() {
    isStale = true
  }

  func recordSuccessfulStart() {
    isStale = false
  }

  func recordStop() {
    lastStopDate = nowProvider()
  }

  /// Fresh controllers were just built: nothing is stale and no stop is old.
  func recordReset() {
    isStale = false
    lastStopDate = nil
  }
}
