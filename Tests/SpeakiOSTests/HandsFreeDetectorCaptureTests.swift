#if os(iOS)
import SpeakCore
import XCTest
@testable import SpeakiOSLib

/// The detector capture without a started engine. Starting one needs a real
/// microphone route, so the arm path is covered on device only.
@MainActor
final class HandsFreeDetectorCaptureTests: XCTestCase {
    func testUnstartedCapture_hasNoEngineAndIsNotRunning() {
        let capture = HandsFreeDetectorCapture(audioSessionManager: AudioSessionManager())
        XCTAssertFalse(capture.hasEngine)
        XCTAssertFalse(capture.isRunning)
    }

    func testResumeWithoutAnEngine_failsAsTheDetector() {
        let capture = HandsFreeDetectorCapture(audioSessionManager: AudioSessionManager())
        XCTAssertThrowsError(try capture.resume()) { error in
            guard case .speechDetectorFailed? = error as? AppleLocalModelError else {
                return XCTFail("expected speechDetectorFailed, got \(error)")
            }
        }
    }

    func testTeardownWithoutAnEngine_isRepeatableAndRetiresNothing() async {
        let capture = HandsFreeDetectorCapture(audioSessionManager: AudioSessionManager())
        capture.pause()
        capture.stopObservingConfiguration()
        await capture.tearDown().cancel()
        await capture.tearDown().cancel()
        XCTAssertFalse(capture.hasEngine)
        XCTAssertThrowsError(try capture.resume())
    }
}
#endif
