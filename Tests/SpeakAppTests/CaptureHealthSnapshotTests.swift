import SpeakCore
import XCTest

@testable import SpeakApp

final class CaptureHealthSnapshotTests: XCTestCase {

  // MARK: - CaptureHealthSnapshot value semantics

  func testSnapshot_defaultEmpty_hasExpectedValues() {
    let snapshot = CaptureHealthSnapshot.empty
    XCTAssertEqual(snapshot.microphonePermission, .notDetermined)
    XCTAssertEqual(snapshot.inputDeviceName, "Unknown")
    XCTAssertEqual(snapshot.providerLabel, "Unknown")
    XCTAssertEqual(snapshot.latencyTier, .medium)
  }

  func testSnapshot_equality_sameValues() {
    let snapshotA = CaptureHealthSnapshot(
      microphonePermission: .granted,
      inputDeviceName: "MacBook Mic",
      providerLabel: "AssemblyAI Universal",
      latencyTier: .fast
    )
    let snapshotB = CaptureHealthSnapshot(
      microphonePermission: .granted,
      inputDeviceName: "MacBook Mic",
      providerLabel: "AssemblyAI Universal",
      latencyTier: .fast
    )
    XCTAssertEqual(snapshotA, snapshotB)
  }

  func testSnapshot_equality_differentPermission() {
    let granted = CaptureHealthSnapshot(
      microphonePermission: .granted,
      inputDeviceName: "MacBook Mic",
      providerLabel: "Apple Speech",
      latencyTier: .instant
    )
    let denied = CaptureHealthSnapshot(
      microphonePermission: .denied,
      inputDeviceName: "MacBook Mic",
      providerLabel: "Apple Speech",
      latencyTier: .instant
    )
    XCTAssertNotEqual(granted, denied)
  }

  func testMicrophonePermission_isGranted_onlyForGranted() {
    XCTAssertTrue(CaptureHealthSnapshot.MicrophonePermission.granted.isGranted)
    XCTAssertFalse(CaptureHealthSnapshot.MicrophonePermission.denied.isGranted)
    XCTAssertFalse(CaptureHealthSnapshot.MicrophonePermission.notDetermined.isGranted)
  }

  // MARK: - HUDManager captureHealth property

  @MainActor
  func testHUDManager_captureHealth_startsEmpty() {
    let manager = HUDManager(appSettings: AppSettings())
    XCTAssertEqual(manager.captureHealth, .empty)
  }

  @MainActor
  func testHUDManager_updateCaptureHealth_storesSnapshot() {
    let manager = HUDManager(appSettings: AppSettings())
    let snapshot = CaptureHealthSnapshot(
      microphonePermission: .granted,
      inputDeviceName: "USB Microphone",
      providerLabel: "Deepgram Nova-3",
      latencyTier: .fast
    )
    manager.updateCaptureHealth(snapshot)
    XCTAssertEqual(manager.captureHealth, snapshot)
  }

  @MainActor
  func testHUDManager_updateCaptureHealth_replacesExistingSnapshot() {
    let manager = HUDManager(appSettings: AppSettings())
    let first = CaptureHealthSnapshot(
      microphonePermission: .denied,
      inputDeviceName: "Built-in Mic",
      providerLabel: "Apple Speech",
      latencyTier: .instant
    )
    let second = CaptureHealthSnapshot(
      microphonePermission: .granted,
      inputDeviceName: "USB Microphone",
      providerLabel: "AssemblyAI Universal",
      latencyTier: .fast
    )
    manager.updateCaptureHealth(first)
    manager.updateCaptureHealth(second)
    XCTAssertEqual(manager.captureHealth, second)
  }
}
