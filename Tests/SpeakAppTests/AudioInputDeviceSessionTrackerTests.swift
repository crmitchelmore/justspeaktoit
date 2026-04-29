import XCTest

@testable import SpeakApp

final class AudioInputDeviceSessionTrackerTests: XCTestCase {
  func testEndSession_DelaysRestoreUntilAllSharedUsersEnd() {
    var tracker = AudioInputDeviceSessionTracker()
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let first = tracker.beginSession(previousDeviceID: 10, didChangeDevice: true, id: firstID)
    let second = tracker.beginSession(previousDeviceID: nil, didChangeDevice: false, id: secondID)

    XCTAssertTrue(first.participatesInSharedSession)
    XCTAssertTrue(second.participatesInSharedSession)
    XCTAssertNil(tracker.endSession(first))
    XCTAssertEqual(tracker.endSession(second), 10)
  }

  func testEndSession_DoesNotRestoreWhenNoDeviceChangeWasActivated() {
    var tracker = AudioInputDeviceSessionTracker()
    let context = tracker.beginSession(
      previousDeviceID: nil,
      didChangeDevice: false,
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    )

    XCTAssertFalse(context.participatesInSharedSession)
    XCTAssertNil(tracker.endSession(context))
  }
}
