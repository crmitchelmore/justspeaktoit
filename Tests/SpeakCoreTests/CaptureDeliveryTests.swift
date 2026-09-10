import XCTest
@testable import SpeakCore

/// Covers the `Auto` destination policy and the receipt it produces, including
/// every failure branch (issue #1008).
final class CaptureDeliveryTests: XCTestCase {

    // MARK: - Policy

    private func inputs(
        empty: Bool = false,
        targetOpen: Bool = false,
        offerAvailable: Bool = true
    ) -> AutoDestinationPolicy.Inputs {
        AutoDestinationPolicy.Inputs(
            transcriptIsEmpty: empty,
            keyboardTargetIsOpen: targetOpen,
            keyboardOfferAvailable: offerAvailable
        )
    }

    func testEmptyTranscriptDeliversNothing() {
        let plan = AutoDestinationPolicy.plan(inputs(empty: true))
        XCTAssertEqual(plan.preferredLane, .none)
        XCTAssertFalse(plan.writesClipboard)
    }

    func testOpenKeyboardWinsAndSkipsTheClipboard() {
        let plan = AutoDestinationPolicy.plan(inputs(targetOpen: true))
        XCTAssertEqual(plan.preferredLane, .keyboardField)
        XCTAssertFalse(plan.writesClipboard)
    }

    func testNoOpenKeyboardFallsBackToTheClipboard() {
        let plan = AutoDestinationPolicy.plan(inputs(targetOpen: false))
        XCTAssertEqual(plan.preferredLane, .clipboard)
        XCTAssertTrue(plan.writesClipboard)
    }

    /// Without Full Access there is no App Group, so an "open keyboard" claim
    /// cannot be honoured even if one were somehow present.
    func testUnavailableOfferStoreForcesTheClipboardEvenWithAnOpenTarget() {
        let plan = AutoDestinationPolicy.plan(inputs(targetOpen: true, offerAvailable: false))
        XCTAssertEqual(plan.preferredLane, .clipboard)
        XCTAssertTrue(plan.writesClipboard)
    }

    func testEveryPlanExplainsItself() {
        for empty in [true, false] {
            for targetOpen in [true, false] {
                for offerAvailable in [true, false] {
                    let plan = AutoDestinationPolicy.plan(
                        inputs(empty: empty, targetOpen: targetOpen, offerAvailable: offerAvailable)
                    )
                    XCTAssertFalse(plan.explanation.isEmpty)
                }
            }
        }
    }

    /// The policy has no Mac lane at all: nothing the phone can observe proves
    /// a Mac is reachable, so Auto never routes on it (issue #952).
    func testPolicyNeverChoosesAMacLane() {
        for empty in [true, false] {
            for targetOpen in [true, false] {
                for offerAvailable in [true, false] {
                    let plan = AutoDestinationPolicy.plan(
                        inputs(empty: empty, targetOpen: targetOpen, offerAvailable: offerAvailable)
                    )
                    XCTAssertTrue(
                        [.none, .clipboard, .keyboardField].contains(plan.preferredLane)
                    )
                }
            }
        }
    }

    // MARK: - Receipt

    private func outcome(
        empty: Bool = false,
        preferred: CaptureDeliveryLane = .clipboard,
        targeted: Bool = false,
        latePickup: Bool = false,
        clipboard: Bool? = true,
        history: Bool = true,
        mac: MacLaneOutcome = .queuedForICloud
    ) -> CaptureReceiptBuilder.Outcome {
        CaptureReceiptBuilder.Outcome(
            transcriptIsEmpty: empty,
            preferredLane: preferred,
            keyboardOfferWasTargeted: targeted,
            keyboardOfferWasLatePickup: latePickup,
            clipboardWriteSucceeded: clipboard,
            savedToHistory: history,
            mac: mac
        )
    }

    func testEmptyCaptureSaysNothingWasDelivered() {
        let receipt = CaptureReceiptBuilder.receipt(for: outcome(empty: true, clipboard: nil))
        XCTAssertEqual(receipt.lane, .none)
        XCTAssertEqual(receipt.headline, "Nothing to deliver")
    }

    func testTargetedOfferReportsTheField() {
        let receipt = CaptureReceiptBuilder.receipt(
            for: outcome(preferred: .keyboardField, targeted: true, clipboard: nil)
        )
        XCTAssertEqual(receipt.lane, .keyboardField)
        XCTAssertTrue(receipt.headline.contains("field"))
        XCTAssertFalse(receipt.summary.lowercased().contains("copied"))
    }

    /// The keyboard closed between the plan and the stop: the receipt reports
    /// the clipboard, which is what actually ran, not the field it aimed at.
    func testKeyboardPlanThatFellBackReportsTheClipboard() {
        let receipt = CaptureReceiptBuilder.receipt(
            for: outcome(preferred: .keyboardField, targeted: false, clipboard: true)
        )
        XCTAssertEqual(receipt.lane, .clipboard)
        XCTAssertEqual(receipt.headline, "Copied")
        XCTAssertTrue(receipt.summary.contains("no longer open"))
    }

    /// A failed pasteboard write must never read as "Copied" (issue #945).
    func testFailedClipboardWriteNeverClaimsACopy() {
        let receipt = CaptureReceiptBuilder.receipt(for: outcome(clipboard: false))
        XCTAssertEqual(receipt.lane, .history)
        XCTAssertEqual(receipt.headline, "Saved to History")
        XCTAssertNotEqual(receipt.headline, "Copied")
        XCTAssertTrue(receipt.summary.contains("did not go through"))
    }

    func testHistoryOnlyReportsHistoryWithoutRepeatingIt() {
        let receipt = CaptureReceiptBuilder.receipt(for: outcome(clipboard: nil, mac: .notAttempted))
        XCTAssertEqual(receipt.lane, .history)
        XCTAssertEqual(receipt.headline, "Saved to History")
        XCTAssertNil(receipt.detail)
    }

    func testEverythingFailingReportsNoDelivery() {
        let receipt = CaptureReceiptBuilder.receipt(
            for: outcome(clipboard: false, history: false, mac: .uploadFailed)
        )
        XCTAssertEqual(receipt.lane, .none)
        XCTAssertEqual(receipt.headline, "Not delivered")
    }

    func testLatePickupOfferIsMentionedAlongsideTheClipboard() {
        let receipt = CaptureReceiptBuilder.receipt(for: outcome(latePickup: true, clipboard: true))
        XCTAssertEqual(receipt.lane, .clipboard)
        XCTAssertTrue(receipt.summary.contains("10 minutes"))
    }

    /// No branch of the receipt may claim a Mac received anything.
    func testNoReceiptEverClaimsMacDelivery() {
        let macCases: [MacLaneOutcome] = [
            .notAttempted, .queuedForICloud, .iCloudUnavailable, .uploadFailed
        ]
        for mac in macCases {
            for targeted in [true, false] {
                for clipboard: Bool? in [true, false, nil] {
                    let receipt = CaptureReceiptBuilder.receipt(
                        for: outcome(targeted: targeted, clipboard: clipboard, mac: mac)
                    )
                    let text = receipt.summary.lowercased()
                    XCTAssertFalse(text.contains("sent to your mac"), text)
                    XCTAssertFalse(text.contains("delivered to"), text)
                    XCTAssertFalse(text.contains("on your mac"), text)
                    XCTAssertFalse(text.contains("pasted"), text)
                }
            }
        }
    }

    func testICloudFailuresAreStatedRatherThanHidden() {
        let unavailable = CaptureReceiptBuilder.receipt(for: outcome(mac: .iCloudUnavailable))
        XCTAssertTrue(unavailable.summary.contains("iCloud is unavailable"))
        let failed = CaptureReceiptBuilder.receipt(for: outcome(mac: .uploadFailed))
        XCTAssertTrue(failed.summary.contains("retried"))
        let queued = CaptureReceiptBuilder.receipt(for: outcome(mac: .queuedForICloud))
        XCTAssertTrue(queued.summary.contains("Queued for iCloud History"))
        XCTAssertNil(MacLaneOutcome.notAttempted.receiptClause)
    }

    // MARK: - Preview

    func testPreviewFlattensAndClips() {
        XCTAssertEqual(TranscriptPreview.short("one\ntwo   three"), "one two three")
        let long = String(repeating: "a", count: 80)
        let short = TranscriptPreview.short(long)
        XCTAssertTrue(short.hasSuffix("\u{2026}"))
        XCTAssertEqual(short.count, TranscriptPreview.defaultLimit + 1)
    }
}
