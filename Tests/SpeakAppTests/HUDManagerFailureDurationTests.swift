import XCTest

@testable import SpeakApp

/// Covers the "Shorten error display" preference: off keeps the historical
/// 6s failure/cancellation duration, on cuts it to 3.6s (50% longer than the
/// 2.4s success duration, per Phill's ruling 2026-08-27). A caller-supplied
/// `displayDuration` always overrides the preference.
final class HUDManagerFailureDurationTests: XCTestCase {
  @MainActor
  func testFailureDisplayDuration_preferenceOff_isStandardSixSeconds() {
    XCTAssertEqual(
      HUDManager.failureDisplayDuration(shortenErrorDisplay: false),
      HUDManager.standardFailureDisplayDuration
    )
    XCTAssertEqual(HUDManager.standardFailureDisplayDuration, 6.0)
  }

  @MainActor
  func testFailureDisplayDuration_preferenceOn_isFiftyPercentLongerThanSuccess() {
    XCTAssertEqual(
      HUDManager.failureDisplayDuration(shortenErrorDisplay: true),
      HUDManager.shortFailureDisplayDuration
    )
    XCTAssertEqual(
      HUDManager.shortFailureDisplayDuration,
      HUDManager.successDisplayDuration * 1.5,
      accuracy: 0.0001
    )
  }

  @MainActor
  func testFinishFailure_preferenceOff_schedulesStandardDuration() {
    let settings = AppSettings()
    settings.shortenErrorDisplay = false
    let manager = HUDManager(appSettings: settings)

    manager.finishFailure(message: "Something broke")

    XCTAssertEqual(manager.lastScheduledAutoHideDuration, HUDManager.standardFailureDisplayDuration)
  }

  @MainActor
  func testFinishFailure_preferenceOn_schedulesShortDuration() {
    let settings = AppSettings()
    settings.shortenErrorDisplay = true
    let manager = HUDManager(appSettings: settings)

    manager.finishFailure(message: "Something broke")

    XCTAssertEqual(manager.lastScheduledAutoHideDuration, HUDManager.shortFailureDisplayDuration)
  }

  @MainActor
  func testFinishFailure_explicitDisplayDurationOverridesPreference() {
    let settings = AppSettings()
    settings.shortenErrorDisplay = true
    let manager = HUDManager(appSettings: settings)

    manager.finishFailure(headline: "Voice edit in progress", message: "Finish or cancel it first.", displayDuration: 3)

    XCTAssertEqual(manager.lastScheduledAutoHideDuration, 3)
  }

  @MainActor
  func testFinishSuccess_durationIsUnaffectedByShortenErrorDisplayPreference() {
    let settings = AppSettings()
    settings.shortenErrorDisplay = true
    let manager = HUDManager(appSettings: settings)

    manager.finishSuccess(message: "Delivered")

    XCTAssertEqual(manager.lastScheduledAutoHideDuration, HUDManager.successDisplayDuration)
  }
}
