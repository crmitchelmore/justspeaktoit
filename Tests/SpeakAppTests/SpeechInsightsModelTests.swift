import XCTest

import SpeakCore
@testable import SpeakApp

/// FileManager that redirects Application Support to a temporary directory so
/// `SpeechInsightsModel` persists its aggregate to an isolated location.
private final class TemporaryApplicationSupportFileManager: FileManager {
  let supportURL: URL

  init(supportURL: URL) {
    self.supportURL = supportURL
    super.init()
  }

  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    guard directory == .applicationSupportDirectory else {
      return super.urls(for: directory, in: domainMask)
    }
    return [supportURL]
  }
}

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

  // MARK: - Refresh invalidation

  /// Acceptance for #682: replacing only the raw transcript of an existing
  /// UUID must update the visible summary and the persisted aggregate, and a
  /// relaunch from disk must agree with the in-memory result.
  @MainActor
  func testRefresh_transcriptEditUnderExistingIDUpdatesSummaryAndPersistedAggregate() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let fileManager = TemporaryApplicationSupportFileManager(supportURL: tempDir)

    let model = SpeechInsightsModel(fileManager: fileManager)
    let original = makeHistoryItem(raw: "alpha alpha alpha", processed: nil, duration: 30)
    model.refresh(using: [original])
    await model.waitForPendingRefresh()
    XCTAssertEqual(model.summary?.topWords.map(\.term), ["alpha"])

    // Same UUID and metadata, new transcript (CloudKit merge / reprocess).
    let edited = makeHistoryItem(
      id: original.id, raw: "bravo bravo", processed: nil, duration: 30
    )
    model.refresh(using: [edited])
    await model.waitForPendingRefresh()
    XCTAssertEqual(model.summary?.topWords.map(\.term), ["bravo"],
                   "stale transcript contribution must be replaced")

    // Relaunch: a fresh model loading the persisted aggregate must agree.
    let relaunched = SpeechInsightsModel(fileManager: fileManager)
    relaunched.refresh(using: [edited])
    await relaunched.waitForPendingRefresh()
    XCTAssertEqual(relaunched.summary, model.summary)
  }

  private func makeHistoryItem(
    id: UUID = UUID(),
    raw: String?,
    processed: String?,
    duration: TimeInterval,
    createdAt: Date = Date(timeIntervalSince1970: 1_785_888_000),
    recordingStarted: Date? = nil,
    recordingEnded: Date? = nil
  ) -> HistoryItem {
    HistoryItem(
      id: id,
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
