import Combine
import Foundation
import XCTest

@testable import SpeakApp

/// The HUD clock used to live inside `HUDManager.Snapshot` and be rewritten by
/// a 50 Hz timer, so every tick republished the whole snapshot - phase,
/// headline, transcripts and all - and re-rendered the entire HUD for the life
/// of a recording. The clock is now derived from `sessionStart`, an instant
/// that only moves on a phase transition, and each HUD style ticks its own
/// label with a `TimelineView` at the resolution it actually displays.
///
/// These tests pin both halves of that: nothing is published between
/// transitions, and the two label formats are byte-for-byte what they were.
final class HUDElapsedClockTests: XCTestCase {
  // MARK: - No periodic publishing

  /// The load-bearing regression test: with the clock running, the manager must
  /// stay silent between phase transitions. Under the old timer this window
  /// carried ~15 snapshot publishes (0.3 s at 0.02 s), each one invalidating
  /// the whole HUD.
  @MainActor
  func testRunningClock_doesNotRepublishSnapshotBetweenTransitions() {
    let manager = HUDManager(appSettings: AppSettings(), accessibilityAnnouncementPoster: { _ in })
    var publishedSnapshots: [HUDManager.Snapshot] = []
    let cancellable = manager.$snapshot
      .dropFirst()  // The initial `.hidden` value every @Published sends on subscribe.
      .sink { publishedSnapshots.append($0) }
    defer { cancellable.cancel() }

    manager.beginRecording()
    let afterTransition = manager.snapshot
    XCTAssertNotNil(manager.sessionStart, "The recording phase must start a clock")

    // Spin the main run loop well past several old timer intervals.
    spinMainRunLoop(for: 0.3)

    XCTAssertEqual(
      publishedSnapshots.count,
      1,
      "The clock must not republish the snapshot; only the transition should publish"
    )
    XCTAssertEqual(
      manager.snapshot,
      afterTransition,
      "The snapshot must be unchanged while only the clock advances"
    )
  }

  /// `sessionStart` is the single high-rate input, and it too changes only on a
  /// transition: one value per phase change, and `nil` for the phases that show
  /// no clock.
  @MainActor
  func testSessionStart_isSetOnlyForPhasesThatShowAClock() {
    let manager = HUDManager(appSettings: AppSettings(), accessibilityAnnouncementPoster: { _ in })

    manager.beginRecording()
    let recordingStart = manager.sessionStart
    XCTAssertNotNil(recordingStart)

    manager.beginTranscribing()
    XCTAssertNotNil(manager.sessionStart)
    XCTAssertNotEqual(manager.sessionStart, recordingStart, "Each phase restarts the clock")

    manager.beginArmed()
    XCTAssertNil(manager.sessionStart, "The armed phase has no running clock")

    manager.beginRecording()
    manager.finishSuccess(message: "Delivered")
    XCTAssertNil(manager.sessionStart, "Terminal phases have no running clock")

    manager.hide()
    XCTAssertNil(manager.sessionStart)
  }

  /// A clock that runs across a phase change restarts, exactly as the old
  /// `Snapshot.elapsed` did when `transition` reset it to zero.
  @MainActor
  func testTransition_restartsTheClockFromZero() {
    let manager = HUDManager(appSettings: AppSettings(), accessibilityAnnouncementPoster: { _ in })

    manager.beginRecording()
    let recordingStart = manager.sessionStart
    spinMainRunLoop(for: 0.1)
    manager.beginPostProcessing()

    guard let recordingStart, let postProcessingStart = manager.sessionStart else {
      return XCTFail("Both phases show a clock, so both must have a start instant")
    }
    XCTAssertGreaterThan(
      postProcessingStart.timeIntervalSince(recordingStart),
      0.05,
      "The new phase's clock must start at the transition, not at the previous phase's start"
    )
  }

  // MARK: - Helpers

  /// Runs the main run loop for `duration`, so any timer that was still
  /// scheduled would get a chance to fire.
  private func spinMainRunLoop(for duration: TimeInterval) {
    let idled = expectation(description: "main run loop spun for \(duration)s")
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { idled.fulfill() }
    wait(for: [idled], timeout: duration + 2)
  }

  // MARK: - Label formatting is unchanged

  /// The full HUD shows seconds and hundredths, growing a minutes field past a
  /// minute. Table pinned against the pre-refactor formatting.
  func testFullHUDElapsedLabel_matchesThePreviousFormatting() {
    let expected: [(TimeInterval, String)] = [
      (-5, "00.00s"),
      (0, "00.00s"),
      (0.004, "00.00s"),
      (0.005, "00.01s"),
      (0.02, "00.02s"),
      (7.78, "07.78s"),
      (59.994, "59.99s"),
      (59.999, "01:00.00"),
      (60, "01:00.00"),
      (83.25, "01:23.25"),
      (600, "10:00.00"),
      (3600, "60:00.00")
    ]
    for (elapsed, label) in expected {
      XCTAssertEqual(HUDOverlay.elapsedLabel(for: elapsed), label, "elapsed \(elapsed)")
    }
  }

  /// The compact HUD shows whole seconds only - which is why its label ticks at
  /// 1 Hz rather than 50 Hz.
  func testCompactElapsedLabel_matchesThePreviousFormatting() {
    let expected: [(TimeInterval, String)] = [
      (-5, "0s"),
      (0, "0s"),
      (0.99, "0s"),
      (7.78, "7s"),
      (59.9, "59s"),
      (60, "1:00s"),
      (83, "1:23s"),
      (600, "10:00s")
    ]
    for (elapsed, label) in expected {
      XCTAssertEqual(CompactHUDContent.elapsedLabel(for: elapsed), label, "elapsed \(elapsed)")
    }
  }
}
