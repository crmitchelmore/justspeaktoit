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

  /// The dashboard caches these aggregations in `@State` and refreshes them on
  /// `HistoryManager.contentRevision` instead of recomputing them in `body`.
  /// The cached values must stay identical to computing them inline.
  func testDashboardAggregatesMatchDirectAggregation() {
    let items = [
      makeHistoryItem(
        modelIdentifier: "openai/gpt-4o-mini-transcribe",
        phase: .transcriptionBatch
      ),
      makeHistoryItem(
        modelIdentifier: "openai/gpt-5-mini",
        phase: .postProcessing
      )
    ]

    let aggregates = DashboardAggregates(items: items)

    XCTAssertEqual(
      aggregates.dailyUsage.map { [$0.date.timeIntervalSince1970, Double($0.count), $0.totalDuration] },
      items.dailyUsageForLastMonth().map { [$0.date.timeIntervalSince1970, Double($0.count), $0.totalDuration] }
    )
    XCTAssertEqual(
      aggregates.transcriptionModels.map(\.modelName),
      items.modelUsage(for: .transcription).map(\.modelName)
    )
    XCTAssertEqual(
      aggregates.postProcessingModels.map(\.modelName),
      items.modelUsage(for: .postProcessing).map(\.modelName)
    )
    XCTAssertEqual(
      aggregates.latencyProviders.map(\.id),
      items.latencyInsightsByProvider().map(\.id)
    )
    XCTAssertEqual(aggregates.latencyOverview.sessionCount, items.latencyOverview().sessionCount)
  }

  /// The dashboard seeds its cache with an empty history before the first
  /// refresh, so that value must match what the charts rendered for an empty
  /// history before the refactor (a zero-filled 30-day series, not "no data").
  func testDashboardAggregatesForEmptyHistoryMatchEmptyAggregation() {
    let aggregates = DashboardAggregates(items: [])

    XCTAssertEqual(aggregates.dailyUsage.count, [HistoryItem]().dailyUsageForLastMonth().count)
    XCTAssertEqual(aggregates.dailyUsage.reduce(0) { $0 + $1.count }, 0, "Every day in the seeded series is empty")
    XCTAssertTrue(aggregates.transcriptionModels.isEmpty)
    XCTAssertTrue(aggregates.postProcessingModels.isEmpty)
    XCTAssertTrue(aggregates.latencyProviders.isEmpty)
    XCTAssertEqual(aggregates.latencyOverview.sessionCount, 0)
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
