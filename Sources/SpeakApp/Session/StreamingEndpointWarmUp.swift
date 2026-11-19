import Foundation
import SpeakCore

/// Keeps the streaming provider's endpoint warm while idle (issue #663): a
/// credential-free HTTPS probe for live clients that use `URLSession.shared`,
/// refreshed before it goes stale and retried after a failure. This warms
/// resolver state and may seed TLS resumption; it does not pre-connect the
/// WebSocket.
@MainActor
final class StreamingEndpointWarmUp {
  /// Called when a scheduled refresh or retry is due; the owner re-checks the
  /// whole environment before probing again.
  var onWake: (@MainActor () -> Void)?
  /// The probe in flight, if any.
  private(set) var probeTask: Task<Void, Never>?
  private var tracker = LiveStreamWarmTracker()
  private let settings: AppSettings
  private let warmer: StreamingEndpointWarming
  private let scheduler: CaptureWarmScheduling
  private let now: @MainActor () -> Date

  static let retryDelay: TimeInterval = 15

  init(
    settings: AppSettings,
    warmer: StreamingEndpointWarming,
    scheduler: CaptureWarmScheduling,
    now: @escaping @MainActor () -> Date
  ) {
    self.settings = settings
    self.warmer = warmer
    self.scheduler = scheduler
    self.now = now
  }

  /// Probes the current provider's host when it needs warming, otherwise
  /// schedules the next refresh.
  func reconcile() {
    let provider = currentStreamingProvider()
    let now = now()
    guard
      let host = tracker.hostNeedingWarmUp(
        for: provider,
        now: now,
        enabled: settings.connectionPreWarmingEnabled
      )
    else {
      scheduleRefresh(for: provider, now: now)
      return
    }

    let warmer = warmer
    probeTask?.cancel()
    probeTask = Task { [weak self] in
      let succeeded = await warmer.warmUp(host: host)
      guard let self, !Task.isCancelled else { return }
      if succeeded {
        let completedAt = self.now()
        if self.tracker.markWarmed(host: host, at: completedAt) {
          self.scheduleRefresh(for: self.currentStreamingProvider(), now: completedAt)
        }
      } else {
        self.tracker.markFailed(host: host)
        self.scheduleWake(after: Self.retryDelay)
      }
    }
  }

  /// Forgets the warm state and stops any probe or scheduled wake.
  func invalidate() {
    scheduler.cancel()
    probeTask?.cancel()
    probeTask = nil
    tracker.invalidate()
  }

  private func scheduleRefresh(for provider: LiveTranscriptionProviderID?, now: Date) {
    guard let deadline = tracker.refreshDeadline(
      for: provider,
      enabled: settings.connectionPreWarmingEnabled
    ) else {
      scheduler.cancel()
      return
    }
    scheduleWake(after: max(0, deadline.timeIntervalSince(now)))
  }

  private func scheduleWake(after delay: TimeInterval) {
    scheduler.schedule(after: delay) { [weak self] in
      self?.onWake?()
    }
  }

  /// The streaming provider a session would use right now, or `nil` when the
  /// current mode does not stream to a cloud provider.
  private func currentStreamingProvider() -> LiveTranscriptionProviderID? {
    guard settings.transcriptionMode == .liveNative else { return nil }
    let availability = ModelCredentialResolver.availability(
      for: settings.liveTranscriptionModel,
      purpose: .liveTranscription,
      storedAPIKeyIdentifiers: settings.trackedAPIKeyIdentifiers
    )
    if case .missing = availability { return nil }
    return LiveTranscriptionRouting.route(for: settings.liveTranscriptionModel)?.provider
  }
}
