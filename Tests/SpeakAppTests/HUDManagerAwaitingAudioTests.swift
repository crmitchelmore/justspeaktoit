import XCTest

@testable import SpeakApp

/// The recording pane appears as soon as a session starts, but its clock must
/// not run until the microphone delivers audio: a clock ticking while no word
/// can be heard read as "the app is recording and missed what I said".
final class HUDManagerAwaitingAudioTests: XCTestCase {
  @MainActor
  private func makeManager(announcements: @escaping (String) -> Void = { _ in }) -> HUDManager {
    HUDManager(appSettings: AppSettings(), accessibilityAnnouncementPoster: announcements)
  }

  @MainActor
  func testAwaitingAudio_showsPaneWithoutRunningClock() {
    let manager = makeManager()

    manager.beginRecording(profileName: nil, awaitingAudio: true)

    XCTAssertEqual(manager.snapshot.phase, .recording, "The pane must be up straight away")
    XCTAssertEqual(manager.snapshot.headline, "Getting ready")
    XCTAssertTrue(manager.isAwaitingAudio)
    XCTAssertNil(manager.sessionStart, "The clock must hold at zero until audio is live")
  }

  @MainActor
  func testMarkAudioLive_startsClockAndShowsRecording() {
    let manager = makeManager()
    manager.beginRecording(profileName: "Mail", awaitingAudio: true)

    let before = Date()
    XCTAssertTrue(manager.markAudioLive())

    XCTAssertFalse(manager.isAwaitingAudio)
    XCTAssertEqual(manager.snapshot.headline, "Recording")
    XCTAssertEqual(manager.snapshot.subheadline, "Profile: Mail")
    guard let start = manager.sessionStart else { return XCTFail("Arrival must start the clock") }
    XCTAssertGreaterThanOrEqual(start, before, "The clock counts from arrival, not from the key press")
  }

  @MainActor
  func testMarkAudioLive_isANoOpOnceLiveOrAfterLeavingRecording() {
    let manager = makeManager()
    manager.beginRecording(awaitingAudio: true)
    XCTAssertTrue(manager.markAudioLive())
    let start = manager.sessionStart
    XCTAssertFalse(manager.markAudioLive(), "A second arrival must not restart the clock")
    XCTAssertEqual(manager.sessionStart, start)

    manager.beginRecording(awaitingAudio: true)
    manager.beginTranscribing()
    XCTAssertFalse(manager.markAudioLive(), "A late arrival must not rewrite a later phase")
    XCTAssertEqual(manager.snapshot.phase, .transcribing)
  }

  @MainActor
  func testRecordingStartedAnnouncement_waitsForAudio() {
    var announcements: [String] = []
    let manager = makeManager { announcements.append($0) }

    manager.beginRecording(awaitingAudio: true)
    XCTAssertTrue(announcements.isEmpty, "Announcing 'Recording started' before audio would invite speech too early")

    manager.markAudioLive()
    XCTAssertEqual(announcements, ["Recording started. Capturing audio"])
  }

  @MainActor
  func testCancelAwaitingAudio_hidesOnlyAPaneStillGettingReady() {
    let manager = makeManager()
    manager.beginRecording(awaitingAudio: true)
    manager.cancelAwaitingAudio()
    XCTAssertEqual(manager.snapshot, .hidden)

    manager.beginRecording(awaitingAudio: true)
    manager.markAudioLive()
    manager.cancelAwaitingAudio()
    XCTAssertEqual(manager.snapshot.phase, .recording, "A live recording pane must stay up")
  }

  @MainActor
  func testDefaultBeginRecording_keepsImmediateClock() {
    let manager = makeManager()
    manager.beginRecording()
    XCTAssertFalse(manager.isAwaitingAudio)
    XCTAssertNotNil(manager.sessionStart)
    XCTAssertEqual(manager.snapshot.headline, "Recording")
  }
}
