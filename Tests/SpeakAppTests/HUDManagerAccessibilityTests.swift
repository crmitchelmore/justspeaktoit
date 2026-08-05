import XCTest

@testable import SpeakApp

final class HUDManagerAccessibilityTests: XCTestCase {
  @MainActor
  func testAccessibilityAnnouncement_describesEveryVisiblePhaseWithoutDuplicatingHeadline() {
    XCTAssertEqual(
      HUDManager.accessibilityAnnouncement(for: .recording, subheadline: "Capturing audio"),
      "Recording started. Capturing audio"
    )
    XCTAssertEqual(
      HUDManager.accessibilityAnnouncement(for: .transcribing, subheadline: "Finalising transcript"),
      "Transcribing. Finalising transcript"
    )
    XCTAssertEqual(
      HUDManager.accessibilityAnnouncement(for: .postProcessing, subheadline: "Cleaning up transcript"),
      "Post-processing. Cleaning up transcript"
    )
    XCTAssertEqual(
      HUDManager.accessibilityAnnouncement(for: .delivering, subheadline: "Pasting into target app"),
      "Delivering transcription. Pasting into target app"
    )
    XCTAssertEqual(
      HUDManager.accessibilityAnnouncement(for: .success(message: "Delivered"), subheadline: "Delivered"),
      "Success. Delivered"
    )
    XCTAssertEqual(
      HUDManager.accessibilityAnnouncement(for: .failure(message: "Network unavailable"), subheadline: nil),
      "Failed. Network unavailable"
    )
  }

  @MainActor
  func testAccessibilityAnnouncement_hiddenPhaseDoesNotAnnounce() {
    XCTAssertNil(HUDManager.accessibilityAnnouncement(for: .hidden, subheadline: nil))
  }

  @MainActor
  func testHide_whenAlreadyHiddenIsANoOp() {
    let manager = HUDManager(appSettings: AppSettings())

    manager.hide()

    XCTAssertEqual(manager.snapshot, .hidden)
  }
}
