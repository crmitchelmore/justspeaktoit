import XCTest

@testable import SpeakApp

@MainActor
final class DeliverySettingsRemedyTests: XCTestCase {
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

  func testForOutput_focusMovedToOriginalApp_SuggestsCurrentApp() {
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: nil,
        warning: nil,
        focusMovedToOtherApplication: true,
        configuration: configuration()
      ),
      .useAppSwitchDelivery(.currentApp)
    )
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: nil,
        warning: TextOutputError.capturedFieldChanged,
        focusMovedToOtherApplication: true,
        configuration: configuration()
      ),
      .useAppSwitchDelivery(.currentApp)
    )
  }

  func testForOutput_focusMovedWithCurrentApp_ReturnsNil() {
    XCTAssertNil(
      DeliverySettingsRemedy.forOutput(
        error: nil,
        warning: nil,
        focusMovedToOtherApplication: true,
        configuration: configuration(appSwitch: .currentApp)
      )
    )
  }

  func testForOutput_heldBackBecauseOriginalAppNotInFront_SuggestsOriginalApp() {
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: TextOutputError.originalApplicationNotInFront("Notes"),
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: configuration(appSwitch: .onlyIfOriginalAppInFront)
      ),
      .useAppSwitchDelivery(.originalApp)
    )
  }

  func testForOutput_originalAppQuit_SuggestsCurrentAppUnlessAlreadyChosen() {
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: TextOutputError.targetApplicationUnavailable,
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: configuration()
      ),
      .useAppSwitchDelivery(.currentApp)
    )
    XCTAssertEqual(
      DeliverySettingsRemedy.forOutput(
        error: TextOutputError.targetApplicationUnavailable,
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: configuration(appSwitch: .onlyIfOriginalAppInFront)
      ),
      .useAppSwitchDelivery(.currentApp)
    )
    XCTAssertNil(
      DeliverySettingsRemedy.forOutput(
        error: TextOutputError.targetApplicationUnavailable,
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: configuration(appSwitch: .currentApp)
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
    let message = DeliverySettingsRemedy.useAppSwitchDelivery(.currentApp).annotate(
      TextOutputError.targetApplicationUnavailable.localizedDescription
    )
    XCTAssertTrue(message.hasPrefix("The original app is no longer available."))
    XCTAssertTrue(message.contains(AppSettings.AppSwitchDelivery.settingName))
    XCTAssertTrue(message.contains(AppSettings.AppSwitchDelivery.currentApp.displayName))
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
      remedy: .useAppSwitchDelivery(.currentApp)
    )
    XCTAssertEqual(
      note,
      "Sent to Notes, where recording started. "
        + DeliverySettingsRemedy.useAppSwitchDelivery(.currentApp).hint
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

    DeliverySettingsRemedy.useAppSwitchDelivery(.onlyIfOriginalAppInFront)
      .apply(settings: settings, permissions: permissions)
    DeliverySettingsRemedy.useSmartTextOutput.apply(settings: settings, permissions: permissions)
    DeliverySettingsRemedy.disableStreamingInsertion.apply(settings: settings, permissions: permissions)

    XCTAssertEqual(settings.appSwitchDelivery, .onlyIfOriginalAppInFront)
    XCTAssertEqual(settings.textOutputMethod, .smart)
    XCTAssertFalse(settings.streamingInsertionEnabled)
  }
}
