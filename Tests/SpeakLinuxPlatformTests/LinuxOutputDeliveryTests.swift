import SpeakDesktop
import SpeakLinuxPlatform
import XCTest

final class LinuxOutputDeliveryTests: XCTestCase {
    func testAcceptedX11Keys_AreNotAcknowledgedInsertion() {
        let native = RecordingNative()
        let result = LinuxOutputJob(
            plan: .x11Paste(window: 9, shift: false, restoreClipboard: false), native: native
        ).performResult("dictated")
        XCTAssertEqual(result.disposition, .unconfirmedInsertion)
        XCTAssertFalse(result.permitsAutomaticResume)
        XCTAssertTrue(result.status.contains("could not be confirmed"))
    }

    func testCopyRecovery_IsNotExplicitClipboardDelivery() {
        let native = RecordingNative()
        let explicit = LinuxOutputJob(plan: .copy(reason: nil), native: native).performResult("dictated")
        let recovery = LinuxOutputJob(
            plan: .copy(reason: "Paste unavailable."), native: native
        ).performResult("dictated")
        XCTAssertEqual(explicit.disposition, .copied)
        XCTAssertTrue(explicit.permitsAutomaticResume)
        XCTAssertEqual(recovery.disposition, .recoveryCopy)
        XCTAssertFalse(recovery.permitsAutomaticResume)
    }

    func testPortalKeySubmission_IsNotAcknowledgedInsertion() {
        let result = LinuxOutputJob(
            plan: .portalPaste(shift: false), native: RecordingNative()
        ).performResult("dictated")
        XCTAssertEqual(result.disposition, .unconfirmedInsertion)
        XCTAssertFalse(result.permitsAutomaticResume)
    }
}
