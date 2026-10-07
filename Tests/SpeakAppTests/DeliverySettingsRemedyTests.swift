import XCTest

@testable import SpeakApp

@MainActor
final class DeliverySettingsRemedyTests: XCTestCase {
  private let ownPID: pid_t = 100
  private let otherPID: pid_t = 200

  private func configuration(
    allowOtherApps: Bool = false,
    method: AppSettings.TextOutputMethod = .smart,
    streaming: Bool = false
  ) -> DeliverySettingsRemedy.Configuration {
    DeliverySettingsRemedy.Configuration(
      allowInsertionIntoOtherApps: allowOtherApps,
      textOutputMethod: method,
      streamingInsertionEnabled: streaming
    )
  }

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

  // MARK: - Remedy mapping

  func testForOutput_cleanDelivery_ReturnsNil() {
    XCTAssertNil(
      DeliverySettingsRemedy.forOutput(
        error: nil,
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: configuration()
      )
    )
  }

  func testForOutput_focusMovedWithSettingOff_SuggestsAllowingOtherApps() {
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: nil,
        warning: nil,
        focusMovedToOtherApplication: true,
        configuration: configuration()
      ),
      .allowInsertionIntoOtherApps
    )
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: nil,
        warning: TextOutputError.capturedFieldChanged,
        focusMovedToOtherApplication: true,
        configuration: configuration()
      ),
      .allowInsertionIntoOtherApps
    )
  }

  func testForOutput_focusMovedWithSettingOn_ReturnsNil() {
    XCTAssertNil(
      DeliverySettingsRemedy.forOutput(
        error: nil,
        warning: nil,
        focusMovedToOtherApplication: true,
        configuration: configuration(allowOtherApps: true)
      )
    )
  }

  func testForOutput_originalAppQuit_SuggestsAllowingOtherAppsOnlyWhenOff() {
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: TextOutputError.targetApplicationUnavailable,
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: configuration()
      ),
      .allowInsertionIntoOtherApps
    )
    XCTAssertNil(
      DeliverySettingsRemedy.forOutput(
        error: TextOutputError.targetApplicationUnavailable,
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: configuration(allowOtherApps: true)
      )
    )
  }

  func testForOutput_accessibilityPermissionMissing_SuggestsGrantingAccess() {
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: TextOutputError.accessibilityPermissionMissing,
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: configuration(method: .accessibilityOnly)
      ),
      .grantAccessibilityPermission
    )
  }

  func testForOutput_accessibilityOnlyFieldFailures_SuggestSmartOutput() {
    let errors: [TextOutputError] = [
      .unableToFindFocusedElement,
      .unableToSetValue(.failure),
      .unableToVerifyInsertion,
      .capturedFieldUnavailable,
      .capturedFieldChanged
    ]
    for error in errors {
      XCTAssertEqual(
        DeliverySettingsRemedy.forOutput(
          error: error,
          warning: nil,
          focusMovedToOtherApplication: false,
          configuration: configuration(method: .accessibilityOnly)
        ),
        .useSmartTextOutput,
        "\(error)"
      )
      XCTAssertNil(
        DeliverySettingsRemedy.forOutput(
          error: error,
          warning: nil,
          focusMovedToOtherApplication: false,
          configuration: configuration(method: .smart)
        ),
        "\(error)"
      )
    }
  }

  func testForOutput_clipboardFailures_ReturnNil() {
    for error in [TextOutputError.clipboardWriteFailed, .pasteShortcutUnavailable] {
      XCTAssertNil(
        DeliverySettingsRemedy.forOutput(
          error: error,
          warning: nil,
          focusMovedToOtherApplication: false,
          configuration: configuration()
        )
      )
    }
  }

  func testForLiveInsertionFailure_streaming_SuggestsTurningStreamingOff() {
    XCTAssertEqual(
      DeliverySettingsRemedy.forLiveInsertionFailure(
        TextOutputError.unableToVerifyInsertion,
        usedStreamingInsertion: true,
        configuration: configuration(streaming: true)
      ),
      .disableStreamingInsertion
    )
    XCTAssertNil(
      DeliverySettingsRemedy.forLiveInsertionFailure(
        TextOutputError.unableToVerifyInsertion,
        usedStreamingInsertion: false,
        configuration: configuration(streaming: true)
      )
    )
  }

  // MARK: - Messages

  func testAnnotate_appendsSettingHint() {
    let message = DeliverySettingsRemedy.allowInsertionIntoOtherApps.annotate(
      TextOutputError.targetApplicationUnavailable.localizedDescription
    )
    XCTAssertTrue(message.hasPrefix("The original app is no longer available."))
    XCTAssertTrue(message.contains(DeliverySettingsRemedy.allowInsertionIntoOtherAppsSettingName))
    XCTAssertTrue(message.contains("Settings › General"))
  }

  func testAnnotate_noRemedy_LeavesMessageUnchanged() {
    let remedy: DeliverySettingsRemedy? = nil
    XCTAssertEqual(remedy.annotate("Failed to write to the clipboard."), "Failed to write to the clipboard.")
  }

  @MainActor
  func testDeliveryNote_focusMoved_NamesOriginalAppAndSetting() {
    let note = MainManager.deliveryNote(
      warning: TextOutputError.capturedFieldChanged,
      focusMovedToOtherApplication: true,
      destination: "Notes",
      remedy: .allowInsertionIntoOtherApps
    )
    XCTAssertEqual(
      note,
      "Sent to Notes, where recording started. "
        + DeliverySettingsRemedy.allowInsertionIntoOtherApps.hint
    )
  }

  @MainActor
  func testDeliveryNote_cleanDelivery_ReturnsNil() {
    XCTAssertNil(
      MainManager.deliveryNote(
        warning: nil,
        focusMovedToOtherApplication: false,
        destination: "Notes",
        remedy: nil
      )
    )
  }

  // MARK: - Applying

  @MainActor
  func testApply_changesTheMatchingSetting() {
    let suiteName = "com.speakapp.delivery-remedy-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    let permissions = PermissionsManager(statusProvider: { _ in .denied })
    settings.textOutputMethod = .accessibilityOnly
    settings.streamingInsertionEnabled = true

    DeliverySettingsRemedy.allowInsertionIntoOtherApps.apply(settings: settings, permissions: permissions)
    DeliverySettingsRemedy.useSmartTextOutput.apply(settings: settings, permissions: permissions)
    DeliverySettingsRemedy.disableStreamingInsertion.apply(settings: settings, permissions: permissions)

    XCTAssertTrue(settings.allowInsertionIntoOtherApps)
    XCTAssertEqual(settings.textOutputMethod, .smart)
    XCTAssertFalse(settings.streamingInsertionEnabled)
  }
}
