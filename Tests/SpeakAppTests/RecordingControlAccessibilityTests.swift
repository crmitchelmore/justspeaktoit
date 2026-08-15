import SwiftUI
import XCTest

@testable import SpeakApp

/// State-matrix coverage for the shared recording-control accessibility
/// derivation used by the MainView toolbar button and both Dashboard record
/// buttons (issue #693).
final class RecordingControlAccessibilityTests: XCTestCase {
  @MainActor
  private func allStates() -> [MainManager.State] {
    [
      .idle,
      .recording,
      .processing,
      .delivering,
      .completed(HistoryItem.placeholder),
      .failed("Network unavailable")
    ]
  }

  @MainActor
  func testStartableStates_useStartLabelHintAndStartsMediaSession() {
    let startableStates: [MainManager.State] = [
      .idle,
      .completed(HistoryItem.placeholder),
      .failed("Network unavailable")
    ]
    for state in startableStates {
      let semantics = RecordingControlAccessibility(state: state)
      XCTAssertEqual(semantics.label, "Start recording", "for state \(state)")
      XCTAssertEqual(semantics.hint, "Starts a new recording", "for state \(state)")
      XCTAssertTrue(semantics.beginsCapture, "for state \(state)")
      XCTAssertEqual(semantics.traits, [.isButton, .startsMediaSession], "for state \(state)")
    }
  }

  @MainActor
  func testRecordingState_announcesStopActionWithoutRelyingOnHints() {
    let semantics = RecordingControlAccessibility(state: .recording)
    XCTAssertEqual(semantics.label, "Stop recording")
    XCTAssertEqual(semantics.hint, "Stops recording and processes the transcription")
    XCTAssertFalse(semantics.beginsCapture)
    XCTAssertEqual(semantics.traits, .isButton)
  }

  @MainActor
  func testBusyStates_describeProgressWithoutActionHint() {
    let processing = RecordingControlAccessibility(state: .processing)
    XCTAssertEqual(processing.label, "Processing recording")
    XCTAssertEqual(processing.hint, "")
    XCTAssertEqual(processing.traits, .isButton)

    let delivering = RecordingControlAccessibility(state: .delivering)
    XCTAssertEqual(delivering.label, "Delivering transcription")
    XCTAssertEqual(delivering.hint, "")
    XCTAssertEqual(delivering.traits, .isButton)
  }

  @MainActor
  func testStartsMediaSession_appearsOnlyWhenActivationBeginsCapture() {
    for state in allStates() {
      let semantics = RecordingControlAccessibility(state: state)
      XCTAssertEqual(
        semantics.traits.contains(.startsMediaSession),
        semantics.beginsCapture,
        "startsMediaSession must track beginsCapture for state \(state)"
      )
      XCTAssertTrue(semantics.traits.contains(.isButton), "for state \(state)")
    }
  }

  @MainActor
  func testEveryState_hasActionOrientedLabelDistinctFromStatusCopy() {
    for state in allStates() {
      let semantics = RecordingControlAccessibility(state: state)
      XCTAssertFalse(semantics.label.isEmpty, "for state \(state)")
      XCTAssertFalse(
        semantics.label.contains("…"),
        "labels must name the action, not progress copy, for state \(state)"
      )
    }
  }
}
