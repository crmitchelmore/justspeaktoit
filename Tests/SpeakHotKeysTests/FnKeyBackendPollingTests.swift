#if os(macOS)
import XCTest

@testable import SpeakHotKeys

/// Exercises the pure cadence policy behind `FnKeyBackend`'s hardware-state
/// poll. Real HID state is never touched here.
final class FnKeyBackendPollingTests: XCTestCase {
  private let baseline = FnKeyPollingPolicy.baselineInterval
  private let escalated = FnKeyPollingPolicy.escalatedInterval

  func testIdleUsesTheBaselineInterval() {
    let interval = FnKeyPollingPolicy.interval(
      isPressed: false,
      secureInput: false,
      recentTapRecovery: false
    )
    XCTAssertEqual(interval, self.baseline)
    XCTAssertEqual(self.baseline, 0.05)
  }

  func testEachConditionEscalatesIndependently() {
    XCTAssertEqual(
      FnKeyPollingPolicy.interval(isPressed: true, secureInput: false, recentTapRecovery: false),
      self.escalated
    )
    XCTAssertEqual(
      FnKeyPollingPolicy.interval(isPressed: false, secureInput: true, recentTapRecovery: false),
      self.escalated
    )
    XCTAssertEqual(
      FnKeyPollingPolicy.interval(isPressed: false, secureInput: false, recentTapRecovery: true),
      self.escalated
    )
    XCTAssertEqual(self.escalated, 0.02)
  }

  func testAllCombinationsOfConditions() {
    for isPressed in [false, true] {
      for secureInput in [false, true] {
        for recentTapRecovery in [false, true] {
          let expected = (isPressed || secureInput || recentTapRecovery)
            ? self.escalated
            : self.baseline
          XCTAssertEqual(
            FnKeyPollingPolicy.interval(
              isPressed: isPressed,
              secureInput: secureInput,
              recentTapRecovery: recentTapRecovery
            ),
            expected,
            "pressed=\(isPressed) secure=\(secureInput) recovery=\(recentTapRecovery)"
          )
        }
      }
    }
  }

  func testBaselineIsCoalescableAndEscalatedIsNot() {
    XCTAssertEqual(
      FnKeyPollingPolicy.tolerance(for: self.baseline),
      self.baseline * 0.2,
      accuracy: 1e-9
    )
    XCTAssertEqual(FnKeyPollingPolicy.tolerance(for: self.baseline), 0.01, accuracy: 1e-9)
    XCTAssertEqual(FnKeyPollingPolicy.tolerance(for: self.escalated), 0)
  }

  /// The whole point of the poll is to catch an Fn edge the event tap missed —
  /// most often a tap made right as a password field takes secure input, before
  /// any escalation could have kicked in. So the *idle* cadence, worst-case
  /// timer slack included, has to fit inside a short tap; the previous 200 ms
  /// baseline could swallow one whole.
  func testBaselineCadenceCannotMissAShortTap() {
    let shortTap: TimeInterval = 0.1
    let worstCaseGap = self.baseline + FnKeyPollingPolicy.tolerance(for: self.baseline)

    XCTAssertLessThan(
      worstCaseGap,
      shortTap,
      "An idle poll tick plus its tolerance must land inside a 100 ms Fn tap"
    )
  }

  /// Still materially cheaper than the fixed-rate poll it replaced.
  func testBaselineStaysBelowTheHistoricalFixedRate() {
    XCTAssertGreaterThan(self.baseline, self.escalated)
    XCTAssertEqual(self.baseline / self.escalated, 2.5, accuracy: 1e-9)
  }

  func testTapRecoveryWindowIsActiveImmediatelyAfterADisable() {
    let disabledAt: TimeInterval = 1_000
    XCTAssertTrue(
      FnKeyPollingPolicy.isWithinTapRecoveryWindow(
        disabledAtUptime: disabledAt,
        nowUptime: disabledAt
      )
    )
    XCTAssertTrue(
      FnKeyPollingPolicy.isWithinTapRecoveryWindow(
        disabledAtUptime: disabledAt,
        nowUptime: disabledAt + FnKeyPollingPolicy.tapRecoveryWindow - 0.01
      )
    )
  }

  func testTapRecoveryWindowExpires() {
    let disabledAt: TimeInterval = 1_000
    XCTAssertFalse(
      FnKeyPollingPolicy.isWithinTapRecoveryWindow(
        disabledAtUptime: disabledAt,
        nowUptime: disabledAt + FnKeyPollingPolicy.tapRecoveryWindow
      )
    )
    XCTAssertFalse(
      FnKeyPollingPolicy.isWithinTapRecoveryWindow(
        disabledAtUptime: disabledAt,
        nowUptime: disabledAt + FnKeyPollingPolicy.tapRecoveryWindow + 5
      )
    )
  }

  func testNoRecordedDisableMeansNoRecoveryWindow() {
    XCTAssertFalse(
      FnKeyPollingPolicy.isWithinTapRecoveryWindow(disabledAtUptime: nil, nowUptime: 1_000)
    )
  }

  func testExpiredRecoveryWindowFallsBackToBaseline() {
    let disabledAt: TimeInterval = 1_000
    let now = disabledAt + FnKeyPollingPolicy.tapRecoveryWindow + 0.5
    let recovering = FnKeyPollingPolicy.isWithinTapRecoveryWindow(
      disabledAtUptime: disabledAt,
      nowUptime: now
    )
    XCTAssertEqual(
      FnKeyPollingPolicy.interval(
        isPressed: false,
        secureInput: false,
        recentTapRecovery: recovering
      ),
      self.baseline
    )
  }

  /// Issue #863: arrow keys, F-keys and the navigation cluster set the
  /// secondary-fn modifier bit while key code 63 stays up. The poll must
  /// decide from the key state alone, so a raised flag with the key up is
  /// never a press, and the key down is a press regardless of the flag.
  func testHardwarePoll_usesKeyCode63Only() {
    XCTAssertFalse(FnKeyBackend.isFnKeyDown(keyState: false), "flag-only (arrow/F-key) must not count as Fn")
    XCTAssertTrue(FnKeyBackend.isFnKeyDown(keyState: true))
  }
}
#endif
