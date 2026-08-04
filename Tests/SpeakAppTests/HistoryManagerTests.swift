import Foundation
import XCTest

import SpeakCore
@testable import SpeakApp

/// FileManager that redirects Application Support to a temporary directory so
/// `HistoryManager` persists to an isolated location during tests.
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

@MainActor
final class HistoryManagerTests: XCTestCase {

  private var tempDir: URL!
  private var fileManager: TemporaryApplicationSupportFileManager!

  private var historyDir: URL {
    tempDir
      .appendingPathComponent("SpeakApp", isDirectory: true)
      .appendingPathComponent("History", isDirectory: true)
  }

  private var walURL: URL {
    historyDir.appendingPathComponent("history-wal.json", isDirectory: false)
  }

  private var storageURL: URL {
    historyDir.appendingPathComponent("history-log.json", isDirectory: false)
  }

  override func setUp() async throws {
    try await super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    fileManager = TemporaryApplicationSupportFileManager(supportURL: tempDir)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
    tempDir = nil
    fileManager = nil
    try await super.tearDown()
  }

  // MARK: - Helpers

  private func makeManager() async -> HistoryManager {
    // Long flush interval and a large batch threshold keep timers and
    // automatic flushes out of the way of the assertions.
    let manager = HistoryManager(
      fileManager: fileManager,
      flushInterval: 3600,
      batchSizeThreshold: 10_000
    )
    // Let the initializer's own async load settle so its completion cannot
    // land in the middle of, and clobber, state the test mutates.
    try? await Task.sleep(for: .milliseconds(200))
    return manager
  }

  private func makeCoder() -> (JSONEncoder, JSONDecoder) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (encoder, decoder)
  }

  private func makeItem(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    duration: TimeInterval = 10,
    cost: Decimal? = nil,
    hasError: Bool = false,
    phaseFallback: (start: Date, end: Date)? = nil
  ) -> HistoryItem {
    HistoryItem(
      id: id,
      createdAt: createdAt,
      modelsUsed: ["apple/local/SFSpeechRecognizer"],
      rawTranscription: "raw transcript",
      postProcessedTranscription: nil,
      recordingDuration: duration,
      cost: cost.map { HistoryCost(total: $0, currency: "USD", breakdown: nil) },
      audioFileURL: nil,
      networkExchanges: [],
      events: [],
      phaseTimestamps: PhaseTimestamps(
        recordingStarted: phaseFallback?.start,
        recordingEnded: phaseFallback?.end,
        transcriptionStarted: nil,
        transcriptionEnded: nil,
        postProcessingStarted: nil,
        postProcessingEnded: nil,
        outputDelivered: nil
      ),
      trigger: HistoryTrigger(
        gesture: .singleTap,
        hotKeyDescription: "Fn",
        outputMethod: .clipboard,
        destinationApplication: nil
      ),
      personalCorrections: nil,
      errors: hasError ? [HistoryError(phase: .transcription, message: "boom")] : []
    )
  }

  private func assertStatisticsMatchFullRecompute(
    _ manager: HistoryManager,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let expected = HistoryManager.calculateStatistics(for: manager.allItems)
    let actual = manager.statistics
    XCTAssertEqual(actual.totalSessions, expected.totalSessions, message, file: file, line: line)
    XCTAssertEqual(
      actual.cumulativeRecordingDuration, expected.cumulativeRecordingDuration,
      accuracy: 0.0001, message, file: file, line: line)
    XCTAssertEqual(actual.totalSpend, expected.totalSpend, message, file: file, line: line)
    XCTAssertEqual(
      actual.averageSessionLength, expected.averageSessionLength,
      accuracy: 0.0001, message, file: file, line: line)
    XCTAssertEqual(
      actual.sessionsWithErrors, expected.sessionsWithErrors, message, file: file, line: line)
  }

  // MARK: - WAL Format Recovery

  func testLegacyArrayWALIsRecoveredAndContinuedInLineFormat() async throws {
    // Arrange: a WAL in the legacy format (single JSON array) from an old build.
    try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
    let legacyItem = makeItem()
    let (encoder, decoder) = makeCoder()
    let legacyWAL = try encoder.encode([WALEntry(operation: .append, item: legacyItem)])
    try legacyWAL.write(to: walURL, options: [.atomic])

    // Act: load — this must replay the legacy WAL into main storage.
    let manager = await makeManager()
    await manager.loadFromDisk()

    // Assert: the legacy entry was recovered and the WAL cleared.
    XCTAssertTrue(manager.allItems.contains { $0.id == legacyItem.id })
    XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
    let persisted = try decoder.decode([HistoryItem].self, from: Data(contentsOf: storageURL))
    XCTAssertTrue(persisted.contains { $0.id == legacyItem.id })

    // Act: append — this must continue in the new line-delimited format.
    let appended = makeItem()
    await manager.append(appended)

    let walData = try Data(contentsOf: walURL)
    let lines = walData.split(separator: 0x0A).filter { !$0.isEmpty }
    XCTAssertEqual(lines.count, 1)
    let lineEntry = try decoder.decode(WALEntry.self, from: Data(lines[0]))
    XCTAssertEqual(lineEntry.operation, .append)
    XCTAssertEqual(lineEntry.item?.id, appended.id)

    // Assert: a fresh manager (simulated crash before flush) recovers the
    // line-format WAL on top of the persisted storage.
    let recovered = await makeManager()
    await recovered.loadFromDisk()
    XCTAssertTrue(recovered.allItems.contains { $0.id == legacyItem.id })
    XCTAssertTrue(recovered.allItems.contains { $0.id == appended.id })
    XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
  }

  func testLineFormatWALSurvivesTornFinalLine() async throws {
    // Arrange: a line-format WAL whose final line was torn by a crash.
    try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
    let item = makeItem()
    let (encoder, _) = makeCoder()
    var walData = try encoder.encode(WALEntry(operation: .append, item: item))
    walData.append(0x0A)
    walData.append(Data("{\"id\":\"truncat".utf8))
    try walData.write(to: walURL, options: [.atomic])

    // Act.
    let manager = await makeManager()
    await manager.loadFromDisk()

    // Assert: the intact entry was recovered; the torn line was skipped.
    XCTAssertTrue(manager.allItems.contains { $0.id == item.id })
    XCTAssertEqual(manager.allItems.count, 1)
  }

  // MARK: - Incremental Statistics

  func testIncrementalStatisticsMatchFullRecomputeAcrossOperations() async throws {
    let manager = await makeManager()
    await manager.loadFromDisk()

    // Append a mix of items: plain, costed, errored, and one that relies on
    // the phase-timestamp duration fallback.
    let plain = makeItem(duration: 12.5)
    let costed = makeItem(duration: 30, cost: Decimal(string: "0.002")!)
    let errored = makeItem(duration: 5, cost: Decimal(string: "0.01")!, hasError: true)
    let now = Date()
    let fallback = makeItem(
      duration: 0,
      phaseFallback: (start: now.addingTimeInterval(-42), end: now)
    )

    for item in [plain, costed, errored, fallback] {
      await manager.append(item)
      assertStatisticsMatchFullRecompute(manager, "after append")
    }

    // Update: change duration, cost, and clear the error.
    let updated = makeItem(
      id: errored.id,
      createdAt: errored.createdAt,
      duration: 8,
      cost: Decimal(string: "0.005")!,
      hasError: false
    )
    await manager.update(updated)
    assertStatisticsMatchFullRecompute(manager, "after update")

    // Remove one by one down to empty.
    for id in [plain.id, costed.id, errored.id, fallback.id] {
      await manager.remove(id: id)
      assertStatisticsMatchFullRecompute(manager, "after remove")
    }
    XCTAssertEqual(manager.statistics.totalSessions, 0)
    XCTAssertEqual(manager.statistics.cumulativeRecordingDuration, 0)
    XCTAssertEqual(manager.statistics.totalSpend, 0)
    XCTAssertEqual(manager.statistics.averageSessionLength, 0)
    XCTAssertEqual(manager.statistics.sessionsWithErrors, 0)
  }

  func testRemoveAllResetsStatistics() async throws {
    let manager = await makeManager()
    await manager.loadFromDisk()

    await manager.append(makeItem(duration: 20, cost: Decimal(string: "0.004")!, hasError: true))
    await manager.append(makeItem(duration: 40))
    assertStatisticsMatchFullRecompute(manager, "after appends")

    await manager.removeAll()
    XCTAssertEqual(manager.statistics.totalSessions, 0)
    XCTAssertEqual(manager.statistics.cumulativeRecordingDuration, 0)
    XCTAssertEqual(manager.statistics.sessionsWithErrors, 0)
  }
}
