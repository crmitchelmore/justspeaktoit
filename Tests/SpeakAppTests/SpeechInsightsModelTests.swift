import XCTest

import SpeakCore
@testable import SpeakApp

final class SpeechInsightsModelTests: XCTestCase {
  func testSessionRecord_usesRawTranscriptAndMetadata() {
    let created = Date(timeIntervalSince1970: 1_785_888_000)
    let item = makeHistoryItem(
      raw: "um hello raw world",
      processed: "Hello, polished world.",
      duration: 42,
      createdAt: created
    )

    let record = SpeechInsightsModel.sessionRecord(from: item)

    XCTAssertEqual(record?.id, item.id)
    XCTAssertEqual(record?.startedAt, created)
    XCTAssertEqual(record?.text, "um hello raw world", "analytics must use the pre-polish transcript")
    XCTAssertEqual(record?.duration, 42)
    XCTAssertEqual(record?.destinationApplication, "Notes")
    XCTAssertEqual(record?.modelIdentifier, "deepgram/nova-3")
  }

  func testSessionRecord_fallsBackToProcessedWhenRawMissing() {
    let item = makeHistoryItem(raw: nil, processed: "Only polished text", duration: 10)
    XCTAssertEqual(SpeechInsightsModel.sessionRecord(from: item)?.text, "Only polished text")
  }

  func testSessionRecord_skipsItemsWithoutText() {
    XCTAssertNil(SpeechInsightsModel.sessionRecord(from: makeHistoryItem(raw: nil, processed: nil, duration: 10)))
    XCTAssertNil(SpeechInsightsModel.sessionRecord(from: makeHistoryItem(raw: "   \n", processed: nil, duration: 10)))
  }

  func testSessionRecord_derivesDurationFromPhaseTimestampsWhenMissing() {
    let start = Date(timeIntervalSince1970: 1_785_888_000)
    let item = makeHistoryItem(
      raw: "hello there",
      processed: nil,
      duration: 0,
      recordingStarted: start,
      recordingEnded: start.addingTimeInterval(90)
    )
    XCTAssertEqual(SpeechInsightsModel.sessionRecord(from: item)?.duration, 90)
  }

  private func makeHistoryItem(
    raw: String?,
    processed: String?,
    duration: TimeInterval,
    createdAt: Date = Date(timeIntervalSince1970: 1_785_888_000),
    recordingStarted: Date? = nil,
    recordingEnded: Date? = nil
  ) -> HistoryItem {
    HistoryItem(
      createdAt: createdAt,
      modelsUsed: ["deepgram/nova-3"],
      modelUsages: [
        ModelUsage(modelIdentifier: "deepgram/nova-3", phase: .transcriptionLive),
        ModelUsage(modelIdentifier: "openai/gpt-5-mini", phase: .postProcessing)
      ],
      rawTranscription: raw,
      postProcessedTranscription: processed,
      recordingDuration: duration,
      cost: nil,
      audioFileURL: nil,
      networkExchanges: [],
      events: [],
      phaseTimestamps: PhaseTimestamps(
        recordingStarted: recordingStarted,
        recordingEnded: recordingEnded,
        transcriptionStarted: nil,
        transcriptionEnded: nil,
        postProcessingStarted: nil,
        postProcessingEnded: nil,
        outputDelivered: nil
      ),
      trigger: HistoryTrigger(
        gesture: .singleTap,
        hotKeyDescription: "Fn",
        outputMethod: .accessibility,
        destinationApplication: "Notes"
      ),
      personalCorrections: nil,
      errors: []
    )
  }
}
