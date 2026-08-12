import SpeakCore
import Foundation

enum SessionTriggerSource {
  case hold
  case doubleTap
  case singleTap
  case uiButton
  case silenceDetection
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
    case .silenceDetection:
      return .uiButton  // Treat as UI-initiated for history purposes
    case .automation:
      return .uiButton  // Shortcuts / App Intents; recorded like a UI trigger
    }
  }
}

final class ActiveSession {
  let id = UUID()
  let gesture: HistoryTrigger.HotKeyGesture
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

  init(gesture: HistoryTrigger.HotKeyGesture, hotKeyDescription: String) {
    self.gesture = gesture
    self.hotKeyDescription = hotKeyDescription
    self.recordingStarted = Date()
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
      hotKeyPressedAt: self.recordingStarted,
      captureStartedAt: self.captureStarted,
      firstPartialAt: self.firstPartialReceived,
      firstInsertAt: self.firstInsertion ?? self.outputDelivered,
      stopPressedAt: self.stopRequested,
      finalInsertAt: self.outputDelivered
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
