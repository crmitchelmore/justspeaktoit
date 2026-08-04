import SpeakCore
import Foundation

enum SessionTriggerSource {
  case hold
  case doubleTap
  case singleTap
  case uiButton
  case silenceDetection

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
      diagnosticContext: diagnosticContext
    )
  }
}
