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

  /// The 30-day window is derived from the reference date, not from the clock,
  /// so a dashboard left open across midnight can rebuild the same series for
  /// the new day instead of keeping yesterday's axis.
  func testDailyUsageWindowEndsOnTheReferenceDate() {
    let calendar = Calendar.current
    let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

    let series = [HistoryItem]().dailyUsageForLastMonth(referenceDate: reference)

    XCTAssertEqual(series.last?.date, reference)
    XCTAssertEqual(
      series.first?.date,
      calendar.date(byAdding: .day, value: -30, to: reference)
    )
    XCTAssertEqual(series.count, 31)
  }

  func testAdvancingTheReferenceDateShiftsTheWholeWindow() {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
      return XCTFail("Calendar should be able to advance one day")
    }

    let before = [HistoryItem]().dailyUsageForLastMonth(referenceDate: today)
    let after = [HistoryItem]().dailyUsageForLastMonth(referenceDate: tomorrow)

    XCTAssertEqual(after.last?.date, tomorrow)
    XCTAssertNotEqual(before.last?.date, after.last?.date)
    XCTAssertEqual(before.count, after.count)
    // Every day but the dropped oldest one is shared, shifted by exactly one slot.
    XCTAssertEqual(before.dropFirst().map(\.date), after.dropLast().map(\.date))
  }

  /// A recording made "today" lands in the last bucket of a window built for
  /// that day, and slides back one bucket once the day rolls over.
  func testTodaysRecordingLandsInTheLastBucketAndSlidesBackAtMidnight() {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    guard
      let noon = calendar.date(byAdding: .hour, value: 12, to: today),
      let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
    else {
      return XCTFail("Calendar should be able to build the fixture dates")
    }
    let items = [
      makeHistoryItem(
        modelIdentifier: "openai/gpt-4o-mini-transcribe",
        phase: .transcriptionBatch,
        createdAt: noon
      )
    ]

    let sameDay = items.dailyUsageForLastMonth(referenceDate: noon)
    XCTAssertEqual(sameDay.last?.count, 1)

    let nextDay = items.dailyUsageForLastMonth(referenceDate: tomorrow)
    XCTAssertEqual(nextDay.last?.count, 0, "The new day starts empty")
    XCTAssertEqual(nextDay.dropLast().last?.count, 1, "Yesterday keeps the recording")
  }

  /// `DashboardAggregates` forwards the reference date, and the dashboard's
  /// cache key carries the day, so a rollover alone invalidates the cache.
  func testDashboardAggregatesRespectTheReferenceDate() {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
      return XCTFail("Calendar should be able to advance one day")
    }

    XCTAssertEqual(DashboardAggregates(items: [], referenceDate: today).dailyUsage.last?.date, today)
    XCTAssertEqual(
      DashboardAggregates(items: [], referenceDate: tomorrow).dailyUsage.last?.date,
      tomorrow
    )
    XCTAssertNotEqual(
      DashboardAggregatesKey(revision: 1, startOfDay: today),
      DashboardAggregatesKey(revision: 1, startOfDay: tomorrow),
      "A day rollover alone must invalidate the dashboard's cached aggregates"
    )
    XCTAssertEqual(
      DashboardAggregatesKey(revision: 1, startOfDay: today),
      DashboardAggregatesKey(revision: 1, startOfDay: today)
    )
  }

  private func makeHistoryItem(
    modelIdentifier: String,
    phase: ModelUsagePhase,
    createdAt: Date = .init()
  ) -> HistoryItem {
    HistoryItem(
      createdAt: createdAt,
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
