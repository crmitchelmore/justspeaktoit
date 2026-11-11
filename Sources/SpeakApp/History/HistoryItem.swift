import SpeakCore
import Foundation

typealias HistoryEvent = ApplicationHistoryEvent
typealias HistoryNetworkExchange = ApplicationHistoryNetworkExchange
typealias HistoryError = ApplicationHistoryError
typealias HistoryTrigger = ApplicationHistoryTrigger
typealias HistoryCost = ApplicationHistoryCost
typealias ModelUsagePhase = ApplicationModelUsagePhase
typealias ModelUsage = ApplicationModelUsage
typealias PostProcessingPromptPayload = ApplicationPostProcessingPromptPayload
typealias PhaseTimestamps = ApplicationPhaseTimestamps
typealias HistoryItemSource = ApplicationHistoryItemSource
typealias HistoryItem = ApplicationHistoryItem

extension HistoryItem {
  static let placeholder: HistoryItem = .init(
    modelsUsed: ["apple/local/SFSpeechRecognizer", ModelCatalog.defaultPostProcessingModel],
    modelUsages: [
      ModelUsage(modelIdentifier: "apple/local/SFSpeechRecognizer", phase: .transcriptionLive),
      ModelUsage(modelIdentifier: ModelCatalog.defaultPostProcessingModel, phase: .postProcessing)
    ],
    rawTranscription: "Hello world, this is a placeholder recording.",
    postProcessedTranscription: "Hello world - this is a placeholder recording.",
    recordingDuration: 32.5,
    cost: .init(total: 0.002, currency: "USD", breakdown: nil),
    audioFileURL: nil,
    networkExchanges: [],
    events: [
      .init(kind: .recordingStarted, description: "Recording began"),
      .init(kind: .recordingStopped, description: "Recording finished"),
      .init(kind: .transcriptionReceived, description: "Transcription succeeded"),
    ],
    phaseTimestamps: .init(
      recordingStarted: Date().addingTimeInterval(-40),
      recordingEnded: Date().addingTimeInterval(-8),
      transcriptionStarted: Date().addingTimeInterval(-8),
      transcriptionEnded: Date().addingTimeInterval(-2),
      postProcessingStarted: nil,
      postProcessingEnded: nil,
      outputDelivered: Date().addingTimeInterval(-1)
    ),
    trigger: .init(
      gesture: .doubleTap,
      hotKeyDescription: "Fn",
      outputMethod: .accessibility,
      destinationApplication: "Notes"
    ),
    personalCorrections: .init(
      applied: [
        PersonalLexiconCorrectionRecord(
          ruleID: UUID(),
          alias: "susie",
          canonical: "Susy",
          occurrences: 1,
          wasApplied: true,
          confidence: .high,
          reason: nil
        )
      ],
      suggestions: [],
      contextTags: ["intimate"],
      destinationApplication: "Messages"
    ),
    errors: []
  )
}

extension HistoryItem {
  var presentationItem: HistoryPresentationItem { historyRecord.presentation }
}
