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
    XCTAssertEqual(
      HUDManager.accessibilityAnnouncement(for: .armed, subheadline: "Hands-free dictation is armed"),
      "Hands-free dictation armed. Hands-free dictation is armed"
    )
  }

  @MainActor
  func testArmedPhaseIsVisibleAndAnnouncedWithoutStartingARecording() {
    var announcements: [String] = []
    let manager = HUDManager(
      appSettings: AppSettings(),
      accessibilityAnnouncementPoster: { announcements.append($0) }
    )

    manager.beginArmed()

    XCTAssertEqual(manager.snapshot.phase, .armed)
    XCTAssertTrue(manager.snapshot.phase.isVisible)
    XCTAssertFalse(manager.snapshot.phase.isTerminal)
    XCTAssertEqual(announcements, ["Hands-free dictation armed. Hands-free dictation is armed"])
  }

  @MainActor
  func testAccessibilityAnnouncement_hiddenPhaseDoesNotAnnounce() {
    XCTAssertNil(HUDManager.accessibilityAnnouncement(for: .hidden, subheadline: nil))
  }

  @MainActor
  func testVisiblePhaseTransitionAndHide_postAccessibilityAnnouncements() {
    var announcements: [String] = []
    let manager = HUDManager(
      appSettings: AppSettings(),
      accessibilityAnnouncementPoster: { announcements.append($0) }
    )

    manager.beginRecording()
    manager.hide()

    XCTAssertEqual(announcements, ["Recording started. Capturing audio", "HUD dismissed"])
    XCTAssertEqual(manager.snapshot, .hidden)
  }

  @MainActor
  func testHide_whenAlreadyHiddenIsANoOp() {
    var announcements: [String] = []
    let manager = HUDManager(
      appSettings: AppSettings(),
      accessibilityAnnouncementPoster: { announcements.append($0) }
    )

    manager.hide()

    XCTAssertEqual(manager.snapshot, .hidden)
    XCTAssertTrue(announcements.isEmpty)
  }
}
