import Foundation
import XCTest
@testable import SpeakCore

/// The decisions behind getting a transcript into the field: when a hardware
/// trigger belongs to the keyboard's session (#1002), when an offer may be
/// shown or inserted (#1003), and when the keyboard hands itself back (#1005).
final class KeyboardDeliveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let documentA = UUID()
    private let documentB = UUID()

    // MARK: - Hardware trigger routing (#1002)

    func testNoKeyboardSession_hardwareTriggerProceedsUnchanged() {
        XCTAssertEqual(KeyboardSessionRouting.decision(handoff: nil, now: now), .proceed)
    }

    func testLiveKeyboardSession_hardwareTriggerFinishesItIntoItsOwnField() {
        for phase in [
            KeyboardHandoffRecord.Phase.recording,
            .finishRequested,
            .transcribing
        ] {
            let record = handoff(phase: phase)
            XCTAssertEqual(
                KeyboardSessionRouting.decision(handoff: record, now: now),
                .finishKeyboardSession(record.requestID),
                "\(phase) should be finished by the physical press"
            )
        }
    }

    func testKeyboardSessionStillStartingUp_hardwareTriggerDoesNotRaceIt() {
        XCTAssertEqual(
            KeyboardSessionRouting.decision(handoff: handoff(phase: .requested), now: now),
            .keyboardSessionStarting
        )
    }

    /// A request the app never progressed must not keep swallowing presses for
    /// the whole three-minute request lifetime; after the start-up grace the
    /// trigger gets its ordinary start/stop behaviour back.
    func testKeyboardRequestNobodyProgressed_stopsSwallowingTriggersAfterTheGrace() {
        let record = handoff(phase: .requested, expiresAt: now.addingTimeInterval(3 * 60))
        XCTAssertEqual(
            KeyboardSessionRouting.decision(
                handoff: record,
                now: now.addingTimeInterval(KeyboardSessionRouting.startupGrace - 0.5)
            ),
            .keyboardSessionStarting
        )
        XCTAssertEqual(
            KeyboardSessionRouting.decision(
                handoff: record,
                now: now.addingTimeInterval(KeyboardSessionRouting.startupGrace + 0.5)
            ),
            .proceed
        )
    }

    func testSettledOrExpiredKeyboardSession_hardwareTriggerProceedsUnchanged() {
        for phase in [KeyboardHandoffRecord.Phase.completed, .cancelled, .failed] {
            XCTAssertEqual(
                KeyboardSessionRouting.decision(handoff: handoff(phase: phase), now: now),
                .proceed
            )
        }
        XCTAssertEqual(
            KeyboardSessionRouting.decision(
                handoff: handoff(phase: .recording, expiresAt: now.addingTimeInterval(-1)),
                now: now
            ),
            .proceed
        )
    }

    // MARK: - Planning an offer (#1002, #1003)

    func testOpenKeyboardTarget_promotesTheCaptureToATargetedInsert() throws {
        let offer = try XCTUnwrap(
            KeyboardDeliveryPlanner.plan(
                transcript: "  put me in the field  ",
                source: .hardwareTrigger,
                target: target(documentIdentifier: documentA),
                now: now
            )
        )
        XCTAssertEqual(offer.mode, .targetedInsert)
        XCTAssertEqual(offer.text, "put me in the field")
        XCTAssertEqual(offer.originDocumentIdentifier, documentA)
        XCTAssertEqual(
            offer.expiresAt,
            now.addingTimeInterval(KeyboardPickupOffer.targetedInsertLifetime)
        )
    }

    func testNoKeyboardTarget_leavesALatePickupThatBelongsToNoDocument() throws {
        let offer = try XCTUnwrap(
            KeyboardDeliveryPlanner.plan(transcript: "for later", source: .watch, target: nil, now: now)
        )
        XCTAssertEqual(offer.mode, .latePickup)
        XCTAssertNil(offer.originDocumentIdentifier)
        XCTAssertEqual(
            offer.expiresAt,
            now.addingTimeInterval(KeyboardPickupOffer.latePickupLifetime)
        )
    }

    func testLapsedOrSecureTarget_isNotATargetForDelivery() throws {
        let lapsed = target(documentIdentifier: documentA, expiresAt: now.addingTimeInterval(-1))
        let secure = target(documentIdentifier: documentA, isSecureField: true)
        for candidate in [lapsed, secure] {
            let offer = try XCTUnwrap(
                KeyboardDeliveryPlanner.plan(
                    transcript: "words", source: .app, target: candidate, now: now
                )
            )
            XCTAssertEqual(offer.mode, .latePickup)
            XCTAssertNil(offer.originDocumentIdentifier)
        }
    }

    func testEmptyTranscript_isNeverOffered() {
        XCTAssertNil(
            KeyboardDeliveryPlanner.plan(transcript: "   \n ", source: .app, target: nil, now: now)
        )
    }

    // MARK: - Consuming an offer (#1002, #1003)

    func testTargetedInsert_landsOnlyInTheDocumentItWasAimedAt() {
        let offer = offer(mode: .targetedInsert, origin: documentA)
        XCTAssertEqual(
            offering(offer, currentDocument: documentA),
            .autoInsert(text: offer.text)
        )
        // A different field gets nothing at all — not even a chip. The user
        // aimed those words somewhere specific.
        XCTAssertEqual(offering(offer, currentDocument: documentB), KeyboardPickupPolicy.Offering.none)
        XCTAssertEqual(offering(offer, currentDocument: nil), KeyboardPickupPolicy.Offering.none)
    }

    func testLatePickup_isOfferedAsAChipAndNeverInsertsItself() {
        let offer = offer(mode: .latePickup, origin: nil, text: "Remind Sam about the invoice")
        guard case let .chip(chip) = offering(offer, currentDocument: documentA) else {
            return XCTFail("a late pickup should be offered as a chip")
        }
        XCTAssertEqual(chip.offerID, offer.offerID)
        XCTAssertEqual(chip.text, offer.text)
        XCTAssertTrue(chip.label.hasPrefix("Insert "))
        XCTAssertTrue(chip.label.contains("Watch"))
        XCTAssertTrue(chip.label.hasSuffix("40 s ago"))
    }

    func testLatePickupAutoInsert_requiresBothTheSettingAndAnExactDocumentMatch() {
        let matching = offer(mode: .latePickup, origin: documentA)
        let opted = KeyboardDeliveryPreferences(autoInsertsMatchingPickup: true)

        XCTAssertEqual(
            offering(matching, currentDocument: documentA, preferences: opted),
            .autoInsert(text: matching.text)
        )
        // Setting on, different field: still only a chip.
        if case .autoInsert = offering(matching, currentDocument: documentB, preferences: opted) {
            XCTFail("auto-insert must never fire in a document the capture did not start in")
        }
        // Document matches, setting off: still only a chip.
        if case .autoInsert = offering(matching, currentDocument: documentA) {
            XCTFail("auto-insert must be opt-in")
        }
    }

    func testAgedOutOfferAndAlreadyClaimedOffer_bothStopBeingOffered() {
        let stale = offer(
            mode: .latePickup,
            origin: nil,
            expiresAt: now.addingTimeInterval(-1)
        )
        XCTAssertEqual(offering(stale, currentDocument: documentA), KeyboardPickupPolicy.Offering.none)

        let taken = offer(mode: .latePickup, origin: nil)
        XCTAssertEqual(
            KeyboardPickupPolicy.offering(
                offer: taken,
                claim: KeyboardPickupClaim(offerID: taken.offerID, claimedAt: now),
                currentDocumentIdentifier: documentA,
                isSecureField: false,
                handoffInFlight: false,
                preferences: .default,
                now: now
            ),
            KeyboardPickupPolicy.Offering.none
        )
    }

    func testSecureFieldAndLiveDictation_bothSuppressEveryOffering() {
        let targeted = offer(mode: .targetedInsert, origin: documentA)
        let late = offer(mode: .latePickup, origin: nil)
        for candidate in [targeted, late] {
            XCTAssertEqual(
                offering(candidate, currentDocument: documentA, isSecureField: true),
                KeyboardPickupPolicy.Offering.none
            )
            XCTAssertEqual(
                offering(candidate, currentDocument: documentA, handoffInFlight: true),
                KeyboardPickupPolicy.Offering.none
            )
        }
    }

    func testPreview_isOneShortLineBecauseItSitsAboveWhateverAppIsFocused() {
        let long = String(repeating: "word ", count: 60)
        let preview = KeyboardPickupPolicy.preview(long)
        XCTAssertLessThanOrEqual(preview.count, KeyboardPickupPolicy.previewLimit + 1)
        XCTAssertTrue(preview.hasSuffix("\u{2026}"))
        XCTAssertEqual(KeyboardPickupPolicy.preview("one\ntwo  three"), "one two three")
    }

    func testAgeDescription_readsInSecondsThenMinutes() {
        XCTAssertEqual(KeyboardPickupPolicy.ageDescription(since: now, now: now), "0 s ago")
        XCTAssertEqual(
            KeyboardPickupPolicy.ageDescription(since: now, now: now.addingTimeInterval(59)),
            "59 s ago"
        )
        XCTAssertEqual(
            KeyboardPickupPolicy.ageDescription(since: now, now: now.addingTimeInterval(9 * 60 + 30)),
            "9 min ago"
        )
    }

    // MARK: - Handing the keyboard back (#1005)

    func testHandBack_onlyWithExactlyTwoKeyboardsBecauseNextIsNotPrevious() {
        let enabled = KeyboardDeliveryPreferences(handsBackAfterInsert: true)
        XCTAssertTrue(
            KeyboardHandBackPolicy.shouldAdvanceToNextInputMode(preferences: enabled, activeInputModeCount: 2)
        )
        for count in [0, 1, 3, 4] {
            XCTAssertFalse(
                KeyboardHandBackPolicy.shouldAdvanceToNextInputMode(
                    preferences: enabled,
                    activeInputModeCount: count
                ),
                "with \(count) keyboards \u{201C}next\u{201D} is not the one the user was typing on"
            )
        }
        XCTAssertFalse(
            KeyboardHandBackPolicy.shouldAdvanceToNextInputMode(
                preferences: KeyboardDeliveryPreferences(handsBackAfterInsert: false),
                activeInputModeCount: 2
            )
        )
    }

    func testCoaching_explainsWhyHandBackIsOffRatherThanSayingNothing() throws {
        let enabled = KeyboardDeliveryPreferences(handsBackAfterInsert: true)
        XCTAssertTrue(try XCTUnwrap(
            KeyboardHandBackPolicy.coaching(preferences: enabled, activeInputModeCount: 4)
        ).contains("4 keyboards"))
        XCTAssertTrue(try XCTUnwrap(
            KeyboardHandBackPolicy.coaching(preferences: enabled, activeInputModeCount: 1)
        ).contains("typing keyboard"))
        XCTAssertNotNil(KeyboardHandBackPolicy.coaching(preferences: enabled, activeInputModeCount: 2))
        XCTAssertNotNil(
            KeyboardHandBackPolicy.coaching(
                preferences: KeyboardDeliveryPreferences(handsBackAfterInsert: false),
                activeInputModeCount: 2
            )
        )
    }
}

private extension KeyboardDeliveryTests {
    // MARK: - Helpers

    func handoff(
        phase: KeyboardHandoffRecord.Phase,
        expiresAt: Date? = nil
    ) -> KeyboardHandoffRecord {
        KeyboardHandoffRecord(
            requestID: UUID(),
            createdAt: now,
            updatedAt: now,
            expiresAt: expiresAt ?? now.addingTimeInterval(60),
            phase: phase,
            targetDocumentIdentifier: documentA
        )
    }

    func target(
        documentIdentifier: UUID,
        expiresAt: Date? = nil,
        isSecureField: Bool = false
    ) -> KeyboardTargetRecord {
        KeyboardTargetRecord(
            documentIdentifier: documentIdentifier,
            updatedAt: now,
            expiresAt: expiresAt ?? now.addingTimeInterval(KeyboardTargetRecord.lifetime),
            isSecureField: isSecureField
        )
    }

    func offer(
        mode: KeyboardPickupOffer.Mode,
        origin: UUID?,
        text: String = "dictated words",
        expiresAt: Date? = nil
    ) -> KeyboardPickupOffer {
        KeyboardPickupOffer(
            text: text,
            source: .watch,
            mode: mode,
            createdAt: now,
            expiresAt: expiresAt ?? now.addingTimeInterval(KeyboardPickupOffer.latePickupLifetime),
            originDocumentIdentifier: origin
        )
    }

    func offering(
        _ offer: KeyboardPickupOffer,
        currentDocument: UUID?,
        isSecureField: Bool = false,
        handoffInFlight: Bool = false,
        preferences: KeyboardDeliveryPreferences = .default
    ) -> KeyboardPickupPolicy.Offering {
        KeyboardPickupPolicy.offering(
            offer: offer,
            claim: nil,
            currentDocumentIdentifier: currentDocument,
            isSecureField: isSecureField,
            handoffInFlight: handoffInFlight,
            preferences: preferences,
            now: now.addingTimeInterval(40)
        )
    }
}
