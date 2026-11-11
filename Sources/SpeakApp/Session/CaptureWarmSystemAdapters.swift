import AppKit
import Foundation
import Network

@MainActor
protocol CaptureWarmScheduling: AnyObject {
  func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () -> Void)
  func cancel()
}

@MainActor
final class SystemCaptureWarmScheduler: CaptureWarmScheduling {
  private var task: Task<Void, Never>?

  func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () -> Void) {
    self.cancel()
    self.task = Task { @MainActor in
      let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      operation()
    }
  }

  func cancel() {
    self.task?.cancel()
    self.task = nil
  }
}

@MainActor
protocol CaptureWarmNetworkMonitoring: AnyObject {
  var statusDidChange: ((NWPath.Status) -> Void)? { get set }
  func start()
  func cancel()
}

@MainActor
final class SystemCaptureWarmNetworkMonitor: CaptureWarmNetworkMonitoring {
  var statusDidChange: ((NWPath.Status) -> Void)?

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.github.speakapp.capture-warm-network")

  func start() {
    self.monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor [weak self] in
        self?.statusDidChange?(path.status)
      }
    }
    self.monitor.start(queue: self.queue)
  }

  func cancel() {
    self.monitor.cancel()
    self.statusDidChange = nil
  }
}

/// The system events that invalidate warm state: sleep and wake, network
/// status changes and stored credential changes. Owns the observer tokens and
/// the network monitor, and removes them in `stop()`.
@MainActor
final class CaptureWarmSystemEvents {
  struct Handlers {
    var willSleep: @MainActor () -> Void
    var didWake: @MainActor () -> Void
    /// The network status changed; true when it is now satisfied.
    var networkChanged: @MainActor (Bool) -> Void
    var credentialsChanged: @MainActor () -> Void
  }

  private let workspaceNotificationCenter: NotificationCenter
  private let notificationCenter: NotificationCenter
  private let networkMonitor: CaptureWarmNetworkMonitoring
  private var workspaceObservers: [NSObjectProtocol] = []
  private var observers: [NSObjectProtocol] = []
  private var lastNetworkStatus: NWPath.Status?

  init(
    workspaceNotificationCenter: NotificationCenter,
    notificationCenter: NotificationCenter,
    networkMonitor: CaptureWarmNetworkMonitoring
  ) {
    self.workspaceNotificationCenter = workspaceNotificationCenter
    self.notificationCenter = notificationCenter
    self.networkMonitor = networkMonitor
  }

  func start(_ handlers: Handlers) {
    let willSleep = workspaceNotificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task { @MainActor in handlers.willSleep() }
    }
    let didWake = workspaceNotificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task { @MainActor in handlers.didWake() }
    }
    workspaceObservers = [willSleep, didWake]

    let credentials = notificationCenter.addObserver(
      forName: .secureAppStorageDidChange,
      object: nil,
      queue: .main
    ) { _ in
      Task { @MainActor in handlers.credentialsChanged() }
    }
    observers.append(credentials)

    networkMonitor.statusDidChange = { [weak self] status in
      guard let self, self.lastNetworkStatus != status else { return }
      self.lastNetworkStatus = status
      handlers.networkChanged(status == .satisfied)
    }
    networkMonitor.start()
  }

  func stop() {
    networkMonitor.cancel()
    for observer in workspaceObservers {
      workspaceNotificationCenter.removeObserver(observer)
    }
    workspaceObservers.removeAll()
    for observer in observers {
      notificationCenter.removeObserver(observer)
    }
    observers.removeAll()
  }
}
