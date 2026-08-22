import XCTest

@testable import SpeakApp

/// The shared-capture reservation between normal dictation and Voice Edit
/// (issue #673).
@MainActor
final class CaptureSessionOwnershipTests: XCTestCase {
  func testReserve_isExclusiveBetweenFlows() {
    let ownership = CaptureSessionOwnership()

    XCTAssertTrue(ownership.reserve(.voiceEdit))
    XCTAssertFalse(ownership.reserve(.dictation), "Dictation must not start on top of Voice Edit")
    XCTAssertTrue(ownership.isHeld(by: .voiceEdit))
    XCTAssertFalse(ownership.isHeld(by: .dictation))

    ownership.release(.voiceEdit)
    XCTAssertNil(ownership.owner)
    XCTAssertTrue(ownership.reserve(.dictation))
    XCTAssertFalse(ownership.reserve(.voiceEdit), "Voice Edit must not start on top of dictation")
  }

  func testReserve_isReentrantForTheHolder() {
    let ownership = CaptureSessionOwnership()
    XCTAssertTrue(ownership.reserve(.dictation))
    XCTAssertTrue(ownership.reserve(.dictation))
    XCTAssertEqual(ownership.owner, .dictation)
  }

  func testRelease_ignoresFlowsThatDoNotHoldTheReservation() {
    let ownership = CaptureSessionOwnership()
    ownership.reserve(.voiceEdit)

    ownership.release(.dictation)

    XCTAssertEqual(ownership.owner, .voiceEdit, "A late release from the other flow must not free it")
    ownership.release(.voiceEdit)
    XCTAssertNil(ownership.owner)
  }

  func testMayTearDownCapture_onlyForTheHolderOrWhenFree() {
    let ownership = CaptureSessionOwnership()
    XCTAssertTrue(ownership.mayTearDownCapture(.dictation))
    XCTAssertTrue(ownership.mayTearDownCapture(.voiceEdit))

    ownership.reserve(.voiceEdit)
    XCTAssertFalse(
      ownership.mayTearDownCapture(.dictation),
      "Dictation's failure cleanup must not cancel Voice Edit's recorder or live stream"
    )
    XCTAssertTrue(ownership.mayTearDownCapture(.voiceEdit))
  }
}
