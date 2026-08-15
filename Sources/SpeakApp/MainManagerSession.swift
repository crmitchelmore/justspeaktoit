import SpeakCore
import Foundation

enum SessionTriggerSource: Equatable {
  case hold
  case doubleTap
  case singleTap
  case uiButton
  case silenceDetection
  /// Started or stopped by hands-free dictation's voice-activity detector.
  case handsFree
  /// Started or stopped by an automation surface (Shortcuts / App Intents,
  /// the `speak` CLI, or the bundled MCP server).
  case automation

  var historyGesture: HistoryTrigger.HotKeyGesture {
    switch self {
    case .hold:
      return .hold
    case .doubleTap:
      return .doubleTap
    case .singleTap:
      return .singleTap
    case .uiButton:
      return .uiButton
    case .silenceDetection, .handsFree:
      return .uiButton  // Treat as UI-initiated for history purposes
    case .automation:
      return .automation  // Shortcuts / App Intents, kept distinct in history
    }
  }
}

/// Wall-clock identity plus an optional monotonic hotkey checkpoint. UI and
/// programmatic starts deliberately omit the monotonic value so they never
/// enter the hotkey-to-capture percentile cohort.
struct SessionTriggerTiming: Equatable {
  let occurredAt: Date
  let hotKeyUptime: TimeInterval?

  static func recognisedHotKey(
    occurredAt: Date = Date(),
    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> SessionTriggerTiming {
    SessionTriggerTiming(occurredAt: occurredAt, hotKeyUptime: uptime)
  }

  static func nonHotKey(occurredAt: Date = Date()) -> SessionTriggerTiming {
    SessionTriggerTiming(occurredAt: occurredAt, hotKeyUptime: nil)
  }

  func milliseconds(to uptime: TimeInterval?) -> Int? {
    guard let start = self.hotKeyUptime, let uptime else { return nil }
    let interval = uptime - start
    guard interval >= 0 else { return nil }
    return Int((interval * 1000).rounded())
  }
}

final class ActiveSession {
  let id = UUID()
  let gesture: HistoryTrigger.HotKeyGesture
  /// What started this session. History only records the gesture, but the
  /// runtime needs the exact source: hands-free captures own their own stop
  /// rules, so level-based auto-stop must keep away from them.
  let trigger: SessionTriggerSource
  let hotKeyDescription: String
  var recordingSummary: RecordingSummary?
  var transcriptionResult: TranscriptionResult?
  var postProcessingOutcome: PostProcessingOutcome?
  var events: [HistoryEvent] = []
  var errors: [HistoryError] = []
  var networkExchanges: [HistoryNetworkExchange] = []
  var modelsUsed: Set<String> = []  // Deprecated: kept for backwards compatibility
  var modelUsages: [ModelUsage] = []
  var totalCost: Decimal = 0
  var costBreakdown: ChatCostBreakdown?
  var recordingStarted: Date
  var recordingEnded: Date?
  /// Latency checkpoints (issue #611): when the recorder actually began
  /// capturing, when the first live partial arrived, when the first character
  /// reached the target app, and when the user requested stop.
  var captureStarted: Date?
  var captureStartedUptime: TimeInterval?
  var firstPartialReceived: Date?
  var firstInsertion: Date?
  var stopRequested: Date?
  var transcriptionStarted: Date?
  var transcriptionEnded: Date?
  var postProcessingStarted: Date?
  var postProcessingEnded: Date?
  var outputDelivered: Date?
  var outputMethod: HistoryTrigger.OutputMethod = .none
  var destination: String?
  var personalCorrections: PersonalLexiconHistorySummary?
  var lexiconContext: PersonalLexiconContext = .empty
  var diagnosticContext: HistoryDiagnosticContext?
  var outputTarget: TextOutputTarget?

  private let triggerTiming: SessionTriggerTiming

  var captureStartMilliseconds: Int? {
    self.triggerTiming.milliseconds(to: self.captureStartedUptime)
  }

  /// - Parameter triggerTiming: wall time for history plus a monotonic uptime
  ///   only when a recognised hotkey initiated this session.
  init(
    gesture: HistoryTrigger.HotKeyGesture,
    hotKeyDescription: String,
    trigger: SessionTriggerSource = .uiButton,
    triggerTiming: SessionTriggerTiming = .nonHotKey()
  ) {
    self.gesture = gesture
    self.trigger = trigger
    self.hotKeyDescription = hotKeyDescription
    self.triggerTiming = triggerTiming
    self.recordingStarted = triggerTiming.occurredAt
  }

  func recordCostFragment(_ fragment: ChatCostBreakdown) {
    totalCost += fragment.totalCost
    costBreakdown = ChatCostBreakdown(
      inputTokens: (costBreakdown?.inputTokens ?? 0) + fragment.inputTokens,
      outputTokens: (costBreakdown?.outputTokens ?? 0) + fragment.outputTokens,
      totalCost: totalCost,
      currency: fragment.currency
    )
  }

  /// Latency intervals derived from this session's checkpoints (issue #611).
  private var latencyMetrics: SessionLatencyMetrics {
    SessionLatencyMetrics(
      captureStartMs: self.captureStartMilliseconds,
      firstPartialMs: SessionLatencyMetrics.milliseconds(
        from: self.captureStarted, to: self.firstPartialReceived
      ),
      firstInsertMs: SessionLatencyMetrics.milliseconds(
        from: self.captureStarted, to: self.firstInsertion ?? self.outputDelivered
      ),
      stopToFinalMs: SessionLatencyMetrics.milliseconds(
        from: self.stopRequested, to: self.outputDelivered
      )
    )
  }

  func buildHistoryItem(finalText: String?, source: HistoryItemSource? = nil) -> HistoryItem {
    let models = Array(modelsUsed)
    let cost: HistoryCost?
    if totalCost > 0, let breakdown = costBreakdown {
      cost = HistoryCost(total: totalCost, currency: breakdown.currency, breakdown: breakdown)
    } else {
      cost = nil
    }

    let createdAt = recordingStarted
    let updatedAt = Date()
    let trigger = HistoryTrigger(
      gesture: gesture,
      hotKeyDescription: hotKeyDescription,
      outputMethod: outputMethod,
      destinationApplication: destination
    )
    let timestamps = PhaseTimestamps(
      recordingStarted: recordingStarted,
      recordingEnded: recordingEnded,
      transcriptionStarted: transcriptionStarted,
      transcriptionEnded: transcriptionEnded,
      postProcessingStarted: postProcessingStarted,
      postProcessingEnded: postProcessingEnded,
      outputDelivered: outputDelivered
    )
    let latency = self.latencyMetrics
    return HistoryItem(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt,
      modelsUsed: models,
      modelUsages: modelUsages,
      rawTranscription: transcriptionResult?.text,
      postProcessedTranscription: postProcessingOutcome?.processed,
      recordingDuration: recordingSummary?.duration ?? 0,
      cost: cost,
      audioFileURL: recordingSummary?.url,
      networkExchanges: networkExchanges,
      events: events,
      phaseTimestamps: timestamps,
      trigger: trigger,
      personalCorrections: personalCorrections,
      errors: errors,
      source: source,
      postProcessingPrompt: postProcessingOutcome?.promptPayload,
      diagnosticContext: diagnosticContext,
      latency: latency.hasAnyInterval ? latency : nil
    )
  }
}
