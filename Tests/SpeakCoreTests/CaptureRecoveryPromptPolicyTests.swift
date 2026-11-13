import Foundation
@testable import SpeakCore
import XCTest

/// Issue #1617: answering "Not now" must stick, so the same interrupted
/// recording is not offered on every launch, while a newer interruption is.
final class CaptureRecoveryPromptPolicyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func finding(at offset: TimeInterval, _ disposition: CaptureRecoveryDisposition = .recoverable)
        -> CaptureRecoveryFinding {
        CaptureRecoveryFinding(
            run: UUID(), fileName: "R\(offset).m4a", startedAt: self.base.addingTimeInterval(offset),
            byteSize: 400_000, disposition: disposition
        )
    }

    func testPromptable_offersOnlyRecoverableCapturesNewerThanTheSnoozeOldestFirst() {
        let old = self.finding(at: 0)
        let middle = self.finding(at: 60)
        let newest = self.finding(at: 120)
        let delivered = self.finding(at: 300, .uncertain(.transcriptAlreadyDelivered))
        let all = [newest, old, delivered, middle]

        XCTAssertEqual(
            CaptureRecoveryPromptPolicy.promptable(all, snoozedThrough: nil).map(\.run),
            [old.run, middle.run, newest.run]
        )
        XCTAssertEqual(
            CaptureRecoveryPromptPolicy.promptable(all, snoozedThrough: old.startedAt).map(\.run),
            [middle.run, newest.run],
            "A capture at the watermark was already put off"
        )
    }

    func testSnoozedThrough_coversEverythingPutOffAndNeverMovesBackwards() {
        let early = self.finding(at: 0)
        let late = self.finding(at: 90)
        let watermark = CaptureRecoveryPromptPolicy.snoozedThrough(after: [late, early], current: nil)
        XCTAssertEqual(watermark, late.startedAt)
        XCTAssertTrue(CaptureRecoveryPromptPolicy.promptable([early, late], snoozedThrough: watermark).isEmpty)

        XCTAssertEqual(
            CaptureRecoveryPromptPolicy.snoozedThrough(after: [early], current: watermark), late.startedAt,
            "Putting off an older capture cannot revive a newer one already put off"
        )
        XCTAssertEqual(CaptureRecoveryPromptPolicy.snoozedThrough(after: [], current: watermark), watermark)
        XCTAssertNil(CaptureRecoveryPromptPolicy.snoozedThrough(after: [], current: nil))
    }
}
