import ApplicationServices
import Foundation
import XCTest

@testable import SpeakApp

/// Cancelling a recording takes back the streamed text (issue #1561), but only
/// when the field holds nothing except this session's own change.
final class LiveTextInserterCancelRollbackTests: XCTestCase {
    @MainActor
    func testCancelAfterStreaming_RemovesTextAndRestoresCaret() {
        let field = FakeStreamingTextField(value: "Dear Sam, ", selection: CFRange(location: 10, length: 0))
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "This cancelled")
        inserter.update(with: "This cancelled recording should not be inserted")

        let result = inserter.rollBackForCancellation()

        XCTAssertEqual(result, .removed)
        XCTAssertEqual(field.value, "Dear Sam, ")
        XCTAssertEqual(field.selection.location, 10)
        XCTAssertEqual(field.selection.length, 0)
        XCTAssertEqual(inserter.insertedText, "")
        XCTAssertFalse(inserter.isActive)
    }

    @MainActor
    func testCancelAfterReplacingSelection_RestoresSelection() {
        let field = FakeStreamingTextField(value: "hello world!", selection: CFRange(location: 6, length: 5))
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "there")

        XCTAssertEqual(inserter.rollBackForCancellation(), .removed)

        XCTAssertEqual(field.value, "hello world!")
        XCTAssertEqual(field.selection.location, 6)
        XCTAssertEqual(field.selection.length, 5)
    }

    @MainActor
    func testCancelAfterUserEditInsideRegion_KeepsDocument() {
        let field = FakeStreamingTextField()
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "hello there")
        field.value = "hello, there"
        let writes = field.selectedTextWrites.count

        guard case .kept = inserter.rollBackForCancellation() else {
            return XCTFail("An edited region must not be removed")
        }
        XCTAssertEqual(field.value, "hello, there")
        XCTAssertEqual(field.selectedTextWrites.count, writes)
    }

    @MainActor
    func testCancelAfterUserTypedNextToRegion_KeepsDocument() {
        let field = FakeStreamingTextField(value: "Intro ", selection: CFRange(location: 6, length: 0))
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "streamed words")
        field.value = "Intro streamed words and mine"
        let writes = field.selectedTextWrites.count

        guard case .kept = inserter.rollBackForCancellation() else {
            return XCTFail("User text around the region must leave the document untouched")
        }
        XCTAssertEqual(field.value, "Intro streamed words and mine")
        XCTAssertEqual(field.selectedTextWrites.count, writes)
        XCTAssertTrue(field.selectedRangeWrites.count <= 1, "Rollback must not move the selection")
    }

    @MainActor
    func testCancelInDifferentNoteBehindSameElement_KeepsDocument() {
        let field = FakeStreamingTextField()
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "hello")
        // #664: Notes reuses the element for another note holding the same words.
        field.value = "hello from another note"

        guard case .kept = inserter.rollBackForCancellation() else {
            return XCTFail("A different note must never be edited on cancel")
        }
        XCTAssertEqual(field.value, "hello from another note")
    }

    @MainActor
    func testCancelInIdenticalNoteWithAnotherDocument_KeepsDocument() {
        let field = FakeStreamingTextField()
        field.documentIdentity = "x-coredata://notes/ICNote/p1"
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "hello")
        // #664: the same element now shows another note that already holds "hello".
        field.documentIdentity = "x-coredata://notes/ICNote/p2"
        let writes = field.selectedTextWrites.count

        guard case .kept = inserter.rollBackForCancellation() else {
            return XCTFail("An identically populated note must never be edited on cancel")
        }
        XCTAssertEqual(field.value, "hello")
        XCTAssertEqual(field.selectedTextWrites.count, writes)
    }

    @MainActor
    func testCancelWhenDocumentIdentityIsUnavailable_KeepsDocument() {
        let field = FakeStreamingTextField()
        // Notes reports no AXDocument, so a switch to an identical note is undetectable.
        field.documentIdentity = nil
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "hello")
        let writes = field.selectedTextWrites.count

        guard case .kept = inserter.rollBackForCancellation() else {
            return XCTFail("Rollback must not delete without a verified document identity")
        }
        XCTAssertEqual(field.value, "hello")
        XCTAssertEqual(field.selectedTextWrites.count, writes)
    }

    @MainActor
    func testCancelAfterPrefixRenormalised_KeepsDocument() {
        let field = FakeStreamingTextField(value: "cafe\u{0301} END", selection: CFRange(location: 6, length: 0))
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "hi")
        XCTAssertEqual(field.value, "cafe\u{0301} hiEND")
        // The editor rewrites the decomposed prefix as NFC: canonically equal, one UTF-16 unit shorter.
        field.value = "caf\u{00E9} hiEND"
        let writes = field.selectedTextWrites.count

        guard case .kept = inserter.rollBackForCancellation() else {
            return XCTFail("A shifted UTF-16 region must not be removed")
        }
        XCTAssertEqual(field.value, "caf\u{00E9} hiEND")
        XCTAssertEqual(field.selectedTextWrites.count, writes)
    }

    @MainActor
    func testCancelWithNothingStreamed_IsNoOp() {
        let field = FakeStreamingTextField(value: "untouched", selection: CFRange(location: 9, length: 0))
        let inserter = LiveTextInserterTestFactory.make(field: field)

        XCTAssertEqual(inserter.rollBackForCancellation(), .nothingInserted)

        XCTAssertEqual(field.value, "untouched")
        XCTAssertTrue(field.selectedTextWrites.isEmpty)
        XCTAssertTrue(field.selectedRangeWrites.isEmpty)
        XCTAssertFalse(inserter.isActive)
    }

    @MainActor
    func testCancelWhenAppRefusesRemoval_KeepsTextUnselected() {
        let field = FakeStreamingTextField()
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "hello")
        field.setSelectedTextResult = .cannotComplete

        guard case .kept = inserter.rollBackForCancellation() else {
            return XCTFail("A refused removal must be reported as kept")
        }
        XCTAssertEqual(field.value, "hello")
        XCTAssertEqual(field.selection.length, 0, "The streamed words must not be left selected")
    }

    @MainActor
    func testStopWithoutCancel_FinalizesInPlace() {
        let field = FakeStreamingTextField(value: "Note: ", selection: CFRange(location: 6, length: 0))
        let inserter = LiveTextInserterTestFactory.make(field: field)
        inserter.update(with: "hello there")

        guard case .applied = inserter.applyPolishedFinal("Hello there.") else {
            return XCTFail("Normal stop must still finalize the streamed region")
        }
        XCTAssertEqual(field.value, "Note: Hello there.")
        XCTAssertEqual(inserter.lastInsertedRange, VoiceEditTextRange(location: 6, length: 12))
    }
}
