#if os(macOS)
import XCTest

@testable import SpeakHotKeys

@MainActor
final class GestureDetectorTests: XCTestCase {
  private let configuration = HotKeyConfiguration(holdThreshold: 0.02, doubleTapWindow: 0.05)

  func testHoldThenRelease_firesABalancedPair() async {
    let recorder = GestureRecorder()
    let detector = makeDetector(recorder: recorder)

    detector.keyDown(source: "test")
    await recorder.waitForHoldStart(in: self)
    detector.keyUp(source: "test")

    XCTAssertEqual(recorder.gestures, [.holdStart, .holdEnd])
    XCTAssertFalse(detector.isHoldInProgress)
  }

  func testResetDuringHold_firesTheMissingHoldEnd() async {
    let recorder = GestureRecorder()
    let detector = makeDetector(recorder: recorder)

    detector.keyDown(source: "test")
    await recorder.waitForHoldStart(in: self)
    detector.reset()

    XCTAssertEqual(recorder.gestures, [.holdStart, .holdEnd])
    XCTAssertFalse(detector.isHoldInProgress)
  }

  func testKeyUpAfterAResetDuringHold_firesNoSecondEnd() async {
    let recorder = GestureRecorder()
    let detector = makeDetector(recorder: recorder)

    detector.keyDown(source: "test")
    await recorder.waitForHoldStart(in: self)
    detector.reset()
    detector.keyUp(source: "test")

    XCTAssertEqual(recorder.gestures, [.holdStart, .holdEnd])
  }

  func testResetWhileIdle_firesNoGesture() {
    let recorder = GestureRecorder()
    let detector = makeDetector(recorder: recorder)

    detector.reset()

    XCTAssertEqual(recorder.gestures, [])
  }

  func testResetBeforeTheHoldThreshold_firesNoGesture() {
    let recorder = GestureRecorder()
    let detector = makeDetector(recorder: recorder)

    detector.keyDown(source: "test")
    detector.reset()

    XCTAssertEqual(recorder.gestures, [])
  }

  func testEngineStopDuringHold_firesTheMissingHoldEnd() async {
    let engine = HotKeyEngine(configuration: configuration)
    let recorder = GestureRecorder()
    engine.register(gesture: .holdStart) { recorder.record(.holdStart) }
    engine.register(gesture: .holdEnd) { recorder.record(.holdEnd) }

    engine.gestureDetector.keyDown(source: "test")
    await recorder.waitForHoldStart(in: self)
    engine.stop()

    XCTAssertEqual(recorder.gestures, [.holdStart, .holdEnd])
    XCTAssertFalse(engine.isKeyDown)
  }

  // MARK: - Helpers

  private func makeDetector(recorder: GestureRecorder) -> GestureDetector {
    let detector = GestureDetector(configuration: configuration)
    detector.onGesture = { recorder.record($0.gesture) }
    return detector
  }
}

/// Collects the gestures a detector emits, and waits for the first hold start.
@MainActor
private final class GestureRecorder {
  private(set) var gestures: [HotKeyGesture] = []
  private var holdStartExpectation: XCTestExpectation?

  func record(_ gesture: HotKeyGesture) {
    gestures.append(gesture)
    if gesture == .holdStart {
      holdStartExpectation?.fulfill()
      holdStartExpectation = nil
    }
  }

  func waitForHoldStart(in testCase: XCTestCase) async {
    guard !gestures.contains(.holdStart) else { return }
    let expectation = testCase.expectation(description: "hold start")
    holdStartExpectation = expectation
    await testCase.fulfillment(of: [expectation], timeout: 1)
  }
}
#endif
