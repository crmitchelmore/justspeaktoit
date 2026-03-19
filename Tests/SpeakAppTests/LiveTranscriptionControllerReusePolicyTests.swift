import Foundation
import XCTest

@testable import SpeakApp

final class LiveControllerReusePolicyTests: XCTestCase {
  func testShouldResetControllersWhenMarkedStale() {
    XCTAssertTrue(
      LiveTranscriptionControllerReusePolicy.shouldResetControllers(
        invalidateBeforeNextStart: true,
        lastStopDate: nil,
        now: Date(timeIntervalSinceReferenceDate: 100)
      )
    )
  }

  func testShouldNotResetControllersForRecentStop() {
    let lastStop = Date(timeIntervalSinceReferenceDate: 1_000)
    let now = lastStop.addingTimeInterval(
      LiveTranscriptionControllerReusePolicy.idleResetThreshold - 1
    )

    XCTAssertFalse(
      LiveTranscriptionControllerReusePolicy.shouldResetControllers(
        invalidateBeforeNextStart: false,
        lastStopDate: lastStop,
        now: now
      )
    )
  }

  func testShouldResetControllersAfterLongIdle() {
    let lastStop = Date(timeIntervalSinceReferenceDate: 1_000)
    let now = lastStop.addingTimeInterval(
      LiveTranscriptionControllerReusePolicy.idleResetThreshold
    )

    XCTAssertTrue(
      LiveTranscriptionControllerReusePolicy.shouldResetControllers(
        invalidateBeforeNextStart: false,
        lastStopDate: lastStop,
        now: now
      )
    )
  }
}
