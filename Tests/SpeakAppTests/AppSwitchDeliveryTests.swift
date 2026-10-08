import XCTest

@testable import SpeakApp

@MainActor
final class AppSwitchDeliveryTests: XCTestCase {
  private let ownPID: pid_t = 100
  private let otherPID: pid_t = 200

  // MARK: - Focus moved to another app

  func testFocusMoved_capturedAppStillFrontmost_ReturnsFalse() {
    XCTAssertFalse(
      SmartTextOutput.focusMovedToOtherApplication(
        capturedApplicationIsFrontmost: true,
        frontmostProcessIdentifier: otherPID,
        ownProcessIdentifier: ownPID
      )
    )
  }

  func testFocusMoved_otherAppFrontmost_ReturnsTrue() {
    XCTAssertTrue(
      SmartTextOutput.focusMovedToOtherApplication(
        capturedApplicationIsFrontmost: false,
        frontmostProcessIdentifier: otherPID,
        ownProcessIdentifier: ownPID
      )
    )
  }

  func testFocusMoved_speakFrontmost_ReturnsFalse() {
    XCTAssertFalse(
      SmartTextOutput.focusMovedToOtherApplication(
        capturedApplicationIsFrontmost: false,
        frontmostProcessIdentifier: ownPID,
        ownProcessIdentifier: ownPID
      )
    )
  }

  func testFocusMoved_noFrontmostApp_ReturnsFalse() {
    XCTAssertFalse(
      SmartTextOutput.focusMovedToOtherApplication(
        capturedApplicationIsFrontmost: false,
        frontmostProcessIdentifier: nil,
        ownProcessIdentifier: ownPID
      )
    )
  }

  // MARK: - App switch decision

  private func decision(
    _ policy: AppSettings.AppSwitchDelivery,
    originalInFront: Bool,
    originalRunning: Bool = true,
    frontmost: pid_t? = 200
  ) -> SmartTextOutput.AppSwitchDecision {
    SmartTextOutput.appSwitchDecision(
      policy: policy,
      capturedApplicationIsFrontmost: originalInFront,
      capturedApplicationIsRunning: originalRunning,
      frontmostProcessIdentifier: frontmost,
      ownProcessIdentifier: ownPID
    )
  }

  func testAppSwitchDecision_originalAppInFront_AlwaysDeliversThere() {
    for policy in AppSettings.AppSwitchDelivery.allCases {
      XCTAssertEqual(decision(policy, originalInFront: true), .deliverToOriginal(focusMoved: false), "\(policy)")
    }
  }

  func testAppSwitchDecision_originalApp_DeliversToOriginalAndFlagsMove() {
    XCTAssertEqual(decision(.originalApp, originalInFront: false), .deliverToOriginal(focusMoved: true))
  }

  func testAppSwitchDecision_currentApp_FollowsUserButNotIntoSpeak() {
    XCTAssertEqual(decision(.currentApp, originalInFront: false), .deliverToCurrentApp)
    XCTAssertEqual(
      decision(.currentApp, originalInFront: false, frontmost: ownPID),
      .deliverToOriginal(focusMoved: false)
    )
  }

  func testAppSwitchDecision_onlyIfOriginalAppInFront_KeepsOnClipboardWhenAnythingElseIsInFront() {
    XCTAssertEqual(decision(.onlyIfOriginalAppInFront, originalInFront: false), .keepOnClipboard)
    XCTAssertEqual(
      decision(.onlyIfOriginalAppInFront, originalInFront: false, frontmost: ownPID),
      .keepOnClipboard
    )
    XCTAssertEqual(decision(.onlyIfOriginalAppInFront, originalInFront: false, frontmost: nil), .keepOnClipboard)
  }

  func testAppSwitchDecision_onlyIfOriginalAppInFront_QuitAppReportsUnavailable() {
    XCTAssertEqual(
      decision(.onlyIfOriginalAppInFront, originalInFront: false, originalRunning: false),
      .deliverToOriginal(focusMoved: false)
    )
  }

  func testOriginalApplicationNotInFront_DescriptionNamesAppAndClipboard() {
    let description = TextOutputError.originalApplicationNotInFront("Notes").localizedDescription
    XCTAssertTrue(description.contains("Notes"))
    XCTAssertTrue(description.contains("clipboard"))
    XCTAssertEqual(
      MainManager.deliveryFailureHeadline(for: TextOutputError.originalApplicationNotInFront(nil)),
      "Not inserted"
    )
    XCTAssertEqual(MainManager.deliveryFailureHeadline(for: TextOutputError.clipboardWriteFailed), "Delivery failed")
  }

  func testEveryOptionHasDistinctNameAndExplanation() {
    let options = AppSettings.AppSwitchDelivery.allCases
    XCTAssertEqual(options.count, 3)
    XCTAssertEqual(Set(options.map(\.displayName)).count, options.count)
    XCTAssertEqual(Set(options.map(\.explanation)).count, options.count)
  }
}
