import XCTest

import SpeakCore
@testable import SpeakApp

final class UsageChartsTests: XCTestCase {
  func testModelUsageForTranscriptionIncludesLocalModelPhase() {
    let items = [
      makeHistoryItem(
        modelIdentifier: "local/whisperkit/huggingface/example/model",
        phase: .transcriptionLocal
      ),
      makeHistoryItem(
        modelIdentifier: "openai/gpt-4o-mini-transcribe",
        phase: .transcriptionBatch
      ),
      makeHistoryItem(
        modelIdentifier: "openai/gpt-5-mini",
        phase: .postProcessing
      )
    ]

    let usage = items.modelUsage(for: .transcription)
    let localUsage = usage.first {
      $0.modelName == ModelCatalog.friendlyName(for: "local/whisperkit/huggingface/example/model")
    }

    XCTAssertEqual(localUsage?.count, 1)
    XCTAssertTrue(usage.contains { $0.modelName == ModelCatalog.friendlyName(for: "openai/gpt-4o-mini-transcribe") })
    XCTAssertFalse(usage.contains { $0.modelName == ModelCatalog.friendlyName(for: "openai/gpt-5-mini") })
  }

  private func makeHistoryItem(modelIdentifier: String, phase: ModelUsagePhase) -> HistoryItem {
    HistoryItem(
      modelsUsed: [modelIdentifier],
      modelUsages: [
        ModelUsage(modelIdentifier: modelIdentifier, phase: phase)
      ],
      rawTranscription: "hello",
      postProcessedTranscription: nil,
      recordingDuration: 1,
      cost: nil,
      audioFileURL: nil,
      networkExchanges: [],
      events: [],
      phaseTimestamps: PhaseTimestamps(
        recordingStarted: nil,
        recordingEnded: nil,
        transcriptionStarted: nil,
        transcriptionEnded: nil,
        postProcessingStarted: nil,
        postProcessingEnded: nil,
        outputDelivered: nil
      ),
      trigger: HistoryTrigger(
        gesture: .uiButton,
        hotKeyDescription: "",
        outputMethod: .none,
        destinationApplication: nil
      ),
      personalCorrections: nil,
      errors: []
    )
  }
}
