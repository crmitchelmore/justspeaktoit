import XCTest
@testable import SpeakCore

/// Covers the `Auto` destination policy and the receipt it produces, including
/// every failure branch (issue #1008).
final class CaptureDeliveryTests: XCTestCase {

    // MARK: - Policy

    private func inputs(
        empty: Bool = false,
        inserted: Bool = false,
        offerAvailable: Bool = true
    ) -> AutoDestinationPolicy.Inputs {
        AutoDestinationPolicy.Inputs(
            transcriptIsEmpty: empty,
            keyboardInsertedIntoField: inserted,
            keyboardOfferAvailable: offerAvailable
        )
    }

    func testEmptyTranscriptDeliversNothing() {
        let plan = AutoDestinationPolicy.plan(inputs(empty: true))
        XCTAssertEqual(plan.preferredLane, .none)
        XCTAssertFalse(plan.writesClipboard)
    }

    func testConfirmedKeyboardInsertionWinsAndSkipsTheClipboard() {
        let plan = AutoDestinationPolicy.plan(inputs(inserted: true))
        XCTAssertEqual(plan.preferredLane, .keyboardField)
        XCTAssertFalse(plan.writesClipboard)
    }

    /// An offer that the keyboard never took is not a delivery, so Auto keeps
    /// the clipboard rather than leaving the words only in History.
    func testKeyboardThatDidNotTakeItFallsBackToTheClipboard() {
        let plan = AutoDestinationPolicy.plan(inputs(inserted: false))
        XCTAssertEqual(plan.preferredLane, .clipboard)
        XCTAssertTrue(plan.writesClipboard)
    }

    /// Without Full Access there is no App Group, so an "open keyboard" claim
    /// cannot be honoured even if one were somehow present.
    func testUnavailableOfferStoreForcesTheClipboardEvenWithAnOpenTarget() {
        let plan = AutoDestinationPolicy.plan(inputs(inserted: true, offerAvailable: false))
        XCTAssertEqual(plan.preferredLane, .clipboard)
        XCTAssertTrue(plan.writesClipboard)
    }

    func testEveryPlanExplainsItself() {
        for empty in [true, false] {
            for inserted in [true, false] {
                for offerAvailable in [true, false] {
                    let plan = AutoDestinationPolicy.plan(
                        inputs(empty: empty, inserted: inserted, offerAvailable: offerAvailable)
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
            for inserted in [true, false] {
                for offerAvailable in [true, false] {
                    let plan = AutoDestinationPolicy.plan(
                        inputs(empty: empty, inserted: inserted, offerAvailable: offerAvailable)
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
        keyboard: CaptureReceiptBuilder.KeyboardOfferOutcome = .notOffered,
        clipboard: Bool? = true,
        history: Bool = true,
        mac: MacLaneOutcome = .queuedForICloud
    ) -> CaptureReceiptBuilder.Outcome {
        CaptureReceiptBuilder.Outcome(
            transcriptIsEmpty: empty,
            preferredLane: preferred,
            keyboard: keyboard,
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

    func testObservedInsertionReportsTheField() {
        let receipt = CaptureReceiptBuilder.receipt(
            for: outcome(preferred: .keyboardField, keyboard: .insertedInField, clipboard: nil)
        )
        XCTAssertEqual(receipt.lane, .keyboardField)
        XCTAssertTrue(receipt.headline.contains("field"))
        XCTAssertFalse(receipt.summary.lowercased().contains("copied"))
    }

    /// The offer was written but the keyboard never took it. The receipt must
    /// not read as a field delivery, and must say the keyboard did not take it
    /// rather than leaving the user to guess where the words are.
    func testPublishedButUnclaimedOfferNeverReportsTheField() {
        let receipt = CaptureReceiptBuilder.receipt(
            for: outcome(
                preferred: .keyboardField,
                keyboard: .targetedButNotInserted,
                clipboard: true
            )
        )
        XCTAssertNotEqual(receipt.lane, .keyboardField)
        XCTAssertEqual(receipt.lane, .clipboard)
        XCTAssertTrue(receipt.summary.contains("did not put it in that field"))
    }

    /// The sweep: for every combination in which the keyboard did not claim
    /// the offer, nothing in the receipt may read as "the words are in your
    /// text field".
    func testNoReceiptClaimsAFieldTheKeyboardNeverTook() {
        let unproven: [CaptureReceiptBuilder.KeyboardOfferOutcome] = [
            .notOffered, .latePickupWaiting, .targetedButNotInserted
        ]
        for keyboard in unproven {
            for preferred: CaptureDeliveryLane in [.keyboardField, .clipboard, .history, .none] {
                for clipboard: Bool? in [true, false, nil] {
                    for history in [true, false] {
                        let receipt = CaptureReceiptBuilder.receipt(
                            for: outcome(
                                preferred: preferred,
                                keyboard: keyboard,
                                clipboard: clipboard,
                                history: history
                            )
                        )
                        let text = receipt.summary.lowercased()
                        XCTAssertNotEqual(receipt.lane, .keyboardField, text)
                        XCTAssertFalse(text.contains("put into the field"), text)
                        XCTAssertFalse(text.contains("put it there"), text)
                    }
                }
            }
        }
    }

    /// The keyboard closed between the plan and the stop: the receipt reports
    /// the clipboard, which is what actually ran, not the field it aimed at.
    func testKeyboardPlanThatFellBackReportsTheClipboard() {
        let receipt = CaptureReceiptBuilder.receipt(
            for: outcome(preferred: .keyboardField, keyboard: .notOffered, clipboard: true)
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
        let receipt = CaptureReceiptBuilder.receipt(
            for: outcome(keyboard: .latePickupWaiting, clipboard: true)
        )
        XCTAssertEqual(receipt.lane, .clipboard)
        XCTAssertTrue(receipt.summary.contains("10 minutes"))
    }

    /// No branch of the receipt may claim a Mac received anything.
    func testNoReceiptEverClaimsMacDelivery() {
        let macCases: [MacLaneOutcome] = [
            .notAttempted, .queuedForICloud, .iCloudUnavailable, .uploadFailed
        ]
        for mac in macCases {
            for keyboard in CaptureReceiptBuilder.KeyboardOfferOutcome.allCases {
                for clipboard: Bool? in [true, false, nil] {
                    let receipt = CaptureReceiptBuilder.receipt(
                        for: outcome(keyboard: keyboard, clipboard: clipboard, mac: mac)
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
