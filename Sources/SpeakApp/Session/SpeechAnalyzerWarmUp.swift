import Foundation
import SpeakCore

/// Loads the selected on-device SpeechAnalyzer model before the first
/// recording, and again after a model, locale or permission change (issue
/// #614). The model is retained for the app's lifetime, so one successful
/// warm-up per selection is enough; a failed one is retried on the next call.
/// It never downloads assets and never opens the microphone.
@MainActor
final class SpeechAnalyzerWarmUp {
  /// The `model|locale` currently loaded. Holding it lists the model in Status
  /// (issue #1471).
  private(set) var warmedKey: String? {
    didSet {
      guard warmedKey != oldValue else { return }
      modelHold?.end()
      modelHold = warmedKey.map { key in
        SystemResourceRegistry.shared.acquire(
          kind: .localModel, title: "Apple SpeechAnalyzer model",
          reason: "Loaded ahead of time so on-device dictation starts quickly. It never opens the microphone.",
          owner: "CaptureWarmCoordinator", detail: key.replacingOccurrences(of: "|", with: " · ")
        )
      }
    }
  }
  /// The warm-up in flight, if any.
  private(set) var task: Task<Void, Never>?
  private var modelHold: SystemResourceToken?
  private var warmingKey: String?
  private let load: @Sendable (_ modelID: String, _ localeIdentifier: String) async -> Bool

  init(warm: @escaping @Sendable (_ modelID: String, _ localeIdentifier: String) async -> Bool) {
    self.load = warm
  }

  /// Loads `model` for `locale` unless it is loaded or loading already.
  func warm(model: String, locale: String) {
    let key = "\(model)|\(locale)"
    guard warmedKey != key, warmingKey != key else { return }
    cancel()
    warmingKey = key
    let load = load
    task = Task(priority: .utility) { [weak self] in
      let succeeded = await load(model, locale)
      guard let self, !Task.isCancelled, self.warmingKey == key else { return }
      self.warmingKey = nil
      self.task = nil
      if succeeded { self.warmedKey = key }
    }
  }

  /// Model loading must not compete with a capture that is starting.
  func cancel() {
    task?.cancel()
    task = nil
    warmingKey = nil
  }

  /// No SpeechAnalyzer model is wanted: stop loading and release the hold.
  func forget() {
    cancel()
    warmedKey = nil
  }

  /// The loaded model may be gone (after sleep): load it again next time.
  func forgetWarmedModel() {
    warmedKey = nil
  }

  nonisolated static func prewarm(modelID: String, localeIdentifier: String) async -> Bool {
    guard #available(macOS 26.0, *) else { return false }
    do {
      try await AppleSpeechAnalyzerWarmup.prewarm(
        engine: AppleSpeechAnalyzerEngine(modelID: modelID),
        localeIdentifier: localeIdentifier
      )
      return true
    } catch {
      if !(error is CancellationError) {
        SpeakLogger.logger(category: "CaptureWarm").info(
          "SpeechAnalyzer warm-up skipped: \(error.localizedDescription, privacy: .public)")
      }
      return false
    }
  }
}
