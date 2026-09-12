import XCTest
@testable import SpeakCore

final class ConfigTransferPresentationTests: XCTestCase {
    func testScanAndCodeAreMutuallyExclusiveAndRevealIsOneWay() {
        var presentation = ConfigTransferPresentation(code: "fixture-code")
        XCTAssertTrue(presentation.isShowingQRCode)
        XCTAssertNil(presentation.visibleCode)
        presentation.revealCode()
        XCTAssertFalse(presentation.isShowingQRCode)
        XCTAssertEqual(presentation.visibleCode, "fixture-code")
        presentation.revealCode()
        XCTAssertFalse(presentation.isShowingQRCode)
        XCTAssertEqual(presentation.visibleCode, "fixture-code")
    }

    func testFreshTransferHidesItsNewCodeDuringScanning() {
        var presentation = ConfigTransferPresentation(code: "old-code")
        presentation.revealCode()
        presentation = ConfigTransferPresentation(code: "new-code")
        XCTAssertTrue(presentation.isShowingQRCode)
        XCTAssertNil(presentation.visibleCode)
        presentation.revealCode()
        XCTAssertEqual(presentation.visibleCode, "new-code")
    }
}
