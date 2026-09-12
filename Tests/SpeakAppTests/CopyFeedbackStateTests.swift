import XCTest

@testable import SpeakApp

final class CopyFeedbackStateTests: XCTestCase {
  func testBegin_startsConfirmationAndReturnsToken() {
    var state = CopyFeedbackState()
    XCTAssertFalse(state.isConfirming)

    let token = state.begin()

    XCTAssertTrue(state.isConfirming)
    XCTAssertEqual(token, state.token)
  }

  func testEnd_withCurrentToken_clearsConfirmation() {
    var state = CopyFeedbackState()
    let token = state.begin()

    state.end(token: token)

    XCTAssertFalse(state.isConfirming)
  }

  func testEnd_withStaleToken_keepsConfirmationVisible() {
    // A second copy restarts the window; the first copy's timer must not clear
    // the checkmark early.
    var state = CopyFeedbackState()
    let firstToken = state.begin()
    let secondToken = state.begin()
    XCTAssertNotEqual(firstToken, secondToken)

    state.end(token: firstToken)
    XCTAssertTrue(state.isConfirming)

    state.end(token: secondToken)
    XCTAssertFalse(state.isConfirming)
  }

  func testConfirmationDuration_isAboutOnePointTwoSeconds() {
    XCTAssertEqual(CopyFeedback.confirmationDuration, .milliseconds(1200))
  }

  func testModelPickerAccessibilityIdentifierComponent_camelCasesTitle() {
    XCTAssertEqual(
      ModelPicker.accessibilityIdentifierComponent(for: "Post-processing Model"),
      "postProcessingModel"
    )
    XCTAssertEqual(ModelPicker.accessibilityIdentifierComponent(for: "Model"), "model")
    XCTAssertEqual(ModelPicker.accessibilityIdentifierComponent(for: "   "), "model")
  }
}
