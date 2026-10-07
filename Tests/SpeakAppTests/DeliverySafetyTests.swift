import XCTest

@testable import SpeakApp

/// Review follow-ups for PR #1187: remedy precedence, stale remedies,
/// redirected-delivery safety and app-name-free History text.
@MainActor
final class DeliverySafetyTests: XCTestCase {
  private func configuration(
    appSwitch: AppSettings.AppSwitchDelivery = .originalApp,
    method: AppSettings.TextOutputMethod = .smart,
    streaming: Bool = false
  ) -> DeliverySettingsRemedy.Configuration {
    DeliverySettingsRemedy.Configuration(
      appSwitchDelivery: appSwitch,
      textOutputMethod: method,
      streamingInsertionEnabled: streaming
    )
  }

  // MARK: - Remedy precedence

  func testForOutput_errorWinsOverFocusMove() {
    for error in [TextOutputError.clipboardWriteFailed, .pasteShortcutUnavailable] {
      XCTAssertNil(
        DeliverySettingsRemedy.forOutput(
          error: error,
          warning: nil,
          focusMovedToOtherApplication: true,
          configuration: configuration()
        ),
        "\(error)"
      )
    }
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: TextOutputError.accessibilityPermissionMissing,
        warning: nil,
        focusMovedToOtherApplication: true,
        configuration: configuration()
      ),
      .grantAccessibilityPermission
    )
  }

  func testForOutput_focusMoveWinsOverWarningWhenDelivered() {
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: nil,
        warning: TextOutputError.capturedFieldChanged,
        focusMovedToOtherApplication: true,
        configuration: configuration(method: .accessibilityOnly)
      ),
      .useAppSwitchDelivery(.currentApp)
    )
  }

  func testForOutput_secondAppSwitch_OffersNoRemedy() {
    XCTAssertNil(
      DeliverySettingsRemedy.forOutput(
        error: TextOutputError.destinationApplicationChanged,
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: configuration(appSwitch: .currentApp)
      )
    )
  }

  // MARK: - Stale remedies

  func testIsSatisfied_tracksTheSettingEachRemedyChanges() {
    let current = configuration(appSwitch: .currentApp, method: .smart, streaming: false)
    XCTAssertTrue(
      DeliverySettingsRemedy.useAppSwitchDelivery(.currentApp)
        .isSatisfied(configuration: current, accessibilityGranted: false)
    )
    XCTAssertFalse(
      DeliverySettingsRemedy.useAppSwitchDelivery(.originalApp)
        .isSatisfied(configuration: current, accessibilityGranted: false)
    )
    XCTAssertTrue(
      DeliverySettingsRemedy.useSmartTextOutput.isSatisfied(configuration: current, accessibilityGranted: false)
    )
    XCTAssertFalse(
      DeliverySettingsRemedy.useSmartTextOutput.isSatisfied(
        configuration: configuration(method: .accessibilityOnly),
        accessibilityGranted: false
      )
    )
    XCTAssertTrue(
      DeliverySettingsRemedy.disableStreamingInsertion.isSatisfied(configuration: current, accessibilityGranted: false)
    )
    XCTAssertFalse(
      DeliverySettingsRemedy.disableStreamingInsertion.isSatisfied(
        configuration: configuration(streaming: true),
        accessibilityGranted: false
      )
    )
    XCTAssertTrue(
      DeliverySettingsRemedy.grantAccessibilityPermission.isSatisfied(
        configuration: current,
        accessibilityGranted: true
      )
    )
    XCTAssertFalse(
      DeliverySettingsRemedy.grantAccessibilityPermission.isSatisfied(
        configuration: current,
        accessibilityGranted: false
      )
    )
  }

  // MARK: - Redirected delivery

  func testDestinationChanged_redirectedTargetStillFrontmost_AllowsDelivery() {
    XCTAssertNil(TextOutputTarget.destinationChangedError(requiresFrontmost: true, isFrontmost: true))
  }

  func testDestinationChanged_redirectedTargetNoLongerFrontmost_FailsClosed() {
    guard case .destinationApplicationChanged? = TextOutputTarget.destinationChangedError(
      requiresFrontmost: true,
      isFrontmost: false
    ) else {
      return XCTFail("Expected destinationApplicationChanged")
    }
  }

  func testDestinationChanged_capturedTarget_IsNotRechecked() {
    XCTAssertNil(TextOutputTarget.destinationChangedError(requiresFrontmost: false, isFrontmost: false))
    let captured = TextOutputTarget(
      processIdentifier: 1,
      applicationName: "Notes",
      bundleIdentifier: nil,
      applicationLaunchDate: nil,
      focusedElement: nil
    )
    XCTAssertNil(captured.destinationChangedError(frontmostProcessIdentifier: 2))
  }

  func testDestinationChanged_redirectedTargetThatQuit_FailsClosed() {
    var redirected = TextOutputTarget(
      processIdentifier: -1,
      applicationName: "Notes",
      bundleIdentifier: nil,
      applicationLaunchDate: nil,
      focusedElement: nil
    )
    redirected.requiresFrontmostAtDelivery = true
    XCTAssertNotNil(redirected.destinationChangedError(frontmostProcessIdentifier: -1))
  }

  func testRedirectDestination_rejectsSpeakAndNoApp() {
    XCTAssertTrue(SmartTextOutput.isUsableRedirectDestination(processIdentifier: 42, ownProcessIdentifier: 7))
    XCTAssertFalse(SmartTextOutput.isUsableRedirectDestination(processIdentifier: 7, ownProcessIdentifier: 7))
    XCTAssertFalse(SmartTextOutput.isUsableRedirectDestination(processIdentifier: nil, ownProcessIdentifier: 7))
  }

  func testDestinationChangedError_HUDHeadlineAndClipboardMessage() {
    let error = TextOutputError.destinationApplicationChanged
    XCTAssertEqual(MainManager.deliveryFailureHeadline(for: error), "Not inserted")
    XCTAssertTrue(error.localizedDescription.contains("clipboard"))
  }

  // MARK: - History privacy

  func testHistorySafeDescription_omitsAppName() {
    let error = TextOutputError.originalApplicationNotInFront("Secret Client Portal")
    XCTAssertTrue(error.localizedDescription.contains("Secret Client Portal"))
    let historyText = MainManager.historySafeDescription(of: error)
    XCTAssertFalse(historyText.contains("Secret Client Portal"))
    XCTAssertTrue(historyText.contains("the app where recording started"))
  }

  func testDeliveryNote_withoutDestination_NamesNoApp() {
    let note = MainManager.deliveryNote(
      warning: nil,
      focusMovedToOtherApplication: true,
      destination: nil,
      remedy: .useAppSwitchDelivery(.currentApp)
    )
    XCTAssertEqual(
      note,
      "Sent to the app where recording started. "
        + DeliverySettingsRemedy.useAppSwitchDelivery(.currentApp).hint
    )
  }
}
