import SpeakCore
import XCTest

@testable import SpeakApp

/// Voice Edit needs cross-app accessibility access the App Store sandbox
/// blocks, so its shortcut must not exist on that channel (issue #673).
final class ShortcutAvailabilityTests: XCTestCase {
  func testVoiceEditFeature_isDirectChannelOnly() {
    XCTAssertTrue(DistributionChannel.direct.supportsVoiceEdit)
    XCTAssertFalse(DistributionChannel.appStore.supportsVoiceEdit)
    XCTAssertEqual(
      DistributionChannel.appStore.supports(.voiceEdit),
      DistributionChannel.appStore.supports(.accessibilityTextInsertion),
      "Voice Edit is gated by the same cross-app access as accessibility insertion"
    )
  }

  func testEditSelectionByVoice_isUnavailableOnTheAppStoreChannel() {
    XCTAssertEqual(ShortcutAction.editSelectionByVoice.requiredChannelFeature, .voiceEdit)
    XCTAssertTrue(ShortcutAction.editSelectionByVoice.isAvailable(in: .direct))
    XCTAssertFalse(ShortcutAction.editSelectionByVoice.isAvailable(in: .appStore))
  }

  func testEveryOtherAction_isAvailableOnEveryChannel() {
    for channel in DistributionChannel.allCases {
      for action in ShortcutAction.allCases where action != .editSelectionByVoice {
        XCTAssertNil(action.requiredChannelFeature, "\(action.displayName) needs no channel gate")
        XCTAssertTrue(action.isAvailable(in: channel), "\(action.displayName) on \(channel)")
      }
    }
  }

  func testAvailableCases_excludeVoiceEditOnlyWhereUnsupported() {
    let appStore = ShortcutAction.availableCases(in: .appStore)
    XCTAssertFalse(appStore.contains(.editSelectionByVoice))
    XCTAssertEqual(appStore.count, ShortcutAction.allCases.count - 1)

    let direct = ShortcutAction.availableCases(in: .direct)
    XCTAssertEqual(direct, ShortcutAction.allCases)
  }
}
