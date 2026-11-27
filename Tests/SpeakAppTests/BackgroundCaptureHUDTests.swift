import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class BackgroundCaptureHUDTests: XCTestCase {
  func testBeginBackgroundRecording_usesBackgroundPillAndPreservesModeUntilHidden() {
    let manager = HUDManager(appSettings: AppSettings(), accessibilityAnnouncementPoster: { _ in })

    manager.beginBackgroundRecording(source: .system)
    XCTAssertEqual(manager.presentationMode, .backgroundPill(source: .system))
    XCTAssertEqual(manager.snapshot.phase, .recording)
    XCTAssertEqual(manager.snapshot.headline, "System Audio")
    XCTAssertFalse(manager.isAwaitingAudio)
    XCTAssertNotNil(manager.sessionStart)

    manager.beginTranscribing(subheadline: "Finalising transcript")
    XCTAssertEqual(
      manager.presentationMode, .backgroundPill(source: .system),
      "Background captures must not flash the full dictation HUD while finalising"
    )

    manager.finishSuccess(message: "Saved", displayDuration: 0)
    XCTAssertEqual(manager.presentationMode, .backgroundPill(source: .system))

    manager.hide()
    XCTAssertEqual(manager.presentationMode, .standard)
  }

  func testBeginBackgroundRecording_bothSourceLabelsCallAudioAndForegroundResetsMode() {
    let manager = HUDManager(appSettings: AppSettings(), accessibilityAnnouncementPoster: { _ in })

    manager.beginBackgroundRecording(source: .both)
    XCTAssertEqual(manager.presentationMode, .backgroundPill(source: .both))
    XCTAssertEqual(manager.snapshot.headline, "Call Audio")

    manager.beginRecording()
    XCTAssertEqual(manager.presentationMode, .standard)
    XCTAssertEqual(manager.snapshot.headline, "Recording")
  }

  func testRequestStop_invokesRegisteredCallback() {
    let manager = HUDManager(appSettings: AppSettings(), accessibilityAnnouncementPoster: { _ in })
    var stopCalls = 0
    manager.onStopRequested = { stopCalls += 1 }

    manager.requestStop()
    XCTAssertEqual(stopCalls, 1)
  }

  func testElapsedLabel_formatsMinutesAndZeroPaddedSeconds() {
    XCTAssertEqual(BackgroundCaptureHUDView.elapsedLabel(for: -1), "0:00")
    XCTAssertEqual(BackgroundCaptureHUDView.elapsedLabel(for: 0), "0:00")
    XCTAssertEqual(BackgroundCaptureHUDView.elapsedLabel(for: 42.9), "0:42")
    XCTAssertEqual(BackgroundCaptureHUDView.elapsedLabel(for: 725), "12:05")
  }
}
