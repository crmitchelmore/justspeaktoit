import XCTest
@testable import SpeakCore
@testable import SpeakiOSLib

/// AppIntents requires compile-time constant literals for a parameter's
/// `default:` and `inclusiveRange:`, so `DictateIntent` cannot spell the
/// `CaptureEndPointingPolicy` constants there and has to repeat the numbers.
///
/// This is the guard on that repetition. If somebody changes a budget in the
/// policy and not in the intent, the Shortcuts editor would go on offering the
/// old range — silently, because the intent clamps whatever it is given and the
/// user would only see a picker that stops at the wrong number. These
/// assertions turn that into a build failure instead.
final class DictateIntentBoundsTests: XCTestCase {
    func testPauseLengthLiteralsMatchThePolicy() {
        XCTAssertEqual(CaptureEndPointingPolicy.defaultSilenceWindowSeconds, 3)
        XCTAssertEqual(CaptureEndPointingPolicy.silenceWindowRange.lowerBound, 2)
        XCTAssertEqual(CaptureEndPointingPolicy.silenceWindowRange.upperBound, 8)
    }

    func testMaximumLengthLiteralsMatchThePolicy() {
        XCTAssertEqual(CaptureEndPointingPolicy.defaultIntentMaximumDurationSeconds, 25)
        XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDurationRange.lowerBound, 5)
        XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDurationRange.upperBound, 60)
    }

    /// The picker's range has to be a range the clamp will actually honour,
    /// or the editor offers values the intent then silently changes.
    func testEveryValueThePickerOffersSurvivesTheClamp() {
        for seconds in stride(from: 2.0, through: 8.0, by: 1.0) {
            XCTAssertEqual(CaptureEndPointingPolicy.silenceWindow(configured: seconds), seconds)
        }
        for seconds in stride(from: 5.0, through: 60.0, by: 5.0) {
            XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDuration(configured: seconds), seconds)
        }
    }

    /// A Shortcut can pass a variable instead of using the picker, so out of
    /// range values reach `perform()` and must be clamped, never honoured.
    func testValuesOutsideThePickerAreClampedRatherThanHonoured() {
        XCTAssertEqual(CaptureEndPointingPolicy.silenceWindow(configured: 0), 2)
        XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDuration(configured: 3_600), 60)
        XCTAssertEqual(CaptureEndPointingPolicy.intentMaximumDuration(configured: -5), 5)
    }
}
