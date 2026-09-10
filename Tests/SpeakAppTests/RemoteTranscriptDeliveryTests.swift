import Foundation
import SpeakCore
import SpeakSync
import XCTest

@testable import SpeakApp

/// The Mac's side of the CloudKit history lane (issue #1007), and the Handoff
/// pointer it can be continued from (issue #1006).
@MainActor
final class RemoteTranscriptDeliveryTests: XCTestCase {

  private var suiteName = ""

  private func makeSettings(autoPaste: Bool) -> AppSettings {
    suiteName = "com.speakapp.remote-transcript-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(defaults: defaults)
    settings.pasteRemoteTranscriptsAtCursor = autoPaste
    return settings
  }

  override func tearDown() {
    if !suiteName.isEmpty {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    super.tearDown()
  }

  private func entry(
    origin: String = "ios",
    age: TimeInterval = 5,
    text: String? = "book the table for eight"
  ) -> SyncableHistoryEntry {
    SyncableHistoryEntry(
      id: UUID(),
      createdAt: Date().addingTimeInterval(-age),
      rawTranscription: text,
      postProcessedText: nil,
      model: "test",
      duration: 3,
      wordCount: 5,
      originPlatform: origin,
      updatedAt: Date()
    )
  }

  private func makeDelivery(
    autoPaste: Bool,
    result: TextOutputResult = TextOutputResult(method: .accessibility, error: nil),
    pasted: @escaping (String) -> Void
  ) -> RemoteTranscriptDelivery {
    RemoteTranscriptDelivery(
      settings: makeSettings(autoPaste: autoPaste),
      paste: { text in
        pasted(text)
        return result
      },
      // No notification centre: a SwiftPM test process has no bundle, and the
      // decision under test is whether anything is pasted, not what is posted.
      notificationCenter: nil
    )
  }

  func testNothingIsPastedWithoutTheOptIn() {
    var pastes: [String] = []
    let delivery = makeDelivery(autoPaste: false) { pastes.append($0) }
    delivery.handle(entry: entry(), isNewToThisMac: true)
    XCTAssertTrue(pastes.isEmpty)
  }

  func testOptInPastesAFreshPhoneCapture() {
    var pastes: [String] = []
    let delivery = makeDelivery(autoPaste: true) { pastes.append($0) }
    delivery.handle(entry: entry(), isNewToThisMac: true)
    XCTAssertEqual(pastes, ["book the table for eight"])
  }

  func testAMacsOwnEntriesAreNeverPastedBack() {
    var pastes: [String] = []
    let delivery = makeDelivery(autoPaste: true) { pastes.append($0) }
    delivery.handle(entry: entry(origin: "macos"), isNewToThisMac: true)
    XCTAssertTrue(pastes.isEmpty)
  }

  func testABacklogOfOldEntriesIsNotPasted() {
    var pastes: [String] = []
    let delivery = makeDelivery(autoPaste: true) { pastes.append($0) }
    delivery.handle(entry: entry(age: 3600), isNewToThisMac: true)
    delivery.handle(entry: entry(), isNewToThisMac: false)
    XCTAssertTrue(pastes.isEmpty)
  }

  // MARK: - Handoff continuation (#1006)

  func testHandoffPastesTheEntryThisMacAlreadyHas() {
    let id = UUID()
    var pastes: [String] = []
    let result = TranscriptHandoffContinuation.handle(
      userInfo: TranscriptHandoffActivityUserInfo.forEntry(id),
      lookup: { $0 == id ? "the synced transcript" : nil },
      paste: { text in
        pastes.append(text)
        return TextOutputResult(method: .accessibility, error: nil)
      },
      presentUnresolved: { _ in XCTFail("the entry was available") }
    )
    XCTAssertEqual(result, .pasted)
    XCTAssertEqual(pastes, ["the synced transcript"])
  }

  /// Handoff is advertised over the local link and can beat the CloudKit round
  /// trip. Saying so is the honest outcome; pasting nothing silently is not.
  func testHandoffForAnUnsyncedEntrySaysSoAndPastesNothing() {
    var pastes: [String] = []
    var messages: [String] = []
    let result = TranscriptHandoffContinuation.handle(
      userInfo: TranscriptHandoffActivityUserInfo.forEntry(UUID()),
      lookup: { _ in nil },
      paste: { text in
        pastes.append(text)
        return TextOutputResult(method: .accessibility, error: nil)
      },
      presentUnresolved: { messages.append($0) }
    )
    XCTAssertEqual(result, .notSyncedYet)
    XCTAssertTrue(pastes.isEmpty)
    XCTAssertEqual(messages.count, 1)
  }

  func testAnUnrelatedActivityIsNotClaimed() {
    let result = TranscriptHandoffContinuation.handle(
      userInfo: ["something": "else"],
      lookup: { _ in "text" },
      paste: { _ in TextOutputResult(method: .accessibility, error: nil) },
      presentUnresolved: { _ in XCTFail("not our activity") }
    )
    XCTAssertEqual(result, .notAPointer)
  }

  func testAFailedPasteIsReportedAsAFailure() {
    let id = UUID()
    let result = TranscriptHandoffContinuation.handle(
      userInfo: TranscriptHandoffActivityUserInfo.forEntry(id),
      lookup: { _ in "text" },
      paste: { _ in TextOutputResult(method: .none, error: TextOutputError.clipboardWriteFailed) },
      presentUnresolved: { _ in XCTFail("the entry was available") }
    )
    guard case .pasteFailed = result else {
      return XCTFail("expected a reported failure, got \(result)")
    }
  }
}

private enum TranscriptHandoffActivityUserInfo {
  static func forEntry(_ id: UUID) -> [AnyHashable: Any] {
    TranscriptHandoffActivity.userInfo(
      for: TranscriptHandoffActivity.Pointer(
        entryID: id,
        createdAt: Date(),
        wordCount: 4,
        originPlatform: "ios"
      )
    )
  }
}
