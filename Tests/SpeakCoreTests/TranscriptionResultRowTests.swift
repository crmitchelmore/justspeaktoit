import XCTest
@testable import SpeakCore

final class TranscriptionResultRowTests: XCTestCase {
    private static let completionID = "9F2C0E1A-0000-4000-8000-00000000ABCD"

    private func completed(
        outcome: TranscriptionCompletionOutcome,
        preview: String = "Raw transcript",
        wordCount: Int = 2,
        completionID: String = TranscriptionResultRowTests.completionID
    ) -> TranscriptionActivityAttributes.ContentState {
        TranscriptionActivityAttributes.ContentState(
            status: .completed,
            wordCount: wordCount,
            completionOutcome: outcome,
            resultPreview: preview,
            resultCompletionID: completionID
        )
    }

    func testRowOnlyExistsForACompletedSession() {
        for status in [TranscriptionActivityAttributes.TranscriptionStatus.idle, .arming, .recording, .error] {
            let state = TranscriptionActivityAttributes.ContentState(status: status, resultPreview: "Hello")
            XCTAssertNil(TranscriptionResultRow(state: state), "\(status) is not a result")
        }
        XCTAssertNotNil(TranscriptionResultRow(state: completed(outcome: .ready)))
    }

    func testHeadlineIsAlwaysTheResolvedOutcomeMessage() {
        for outcome in TranscriptionCompletionOutcome.allCases {
            let row = TranscriptionResultRow(state: completed(outcome: outcome))
            XCTAssertEqual(row?.outcomeMessage, outcome.message, "The row must not re-word the outcome")
        }
    }

    func testAnUnconfirmedOutcomeStillOffersCopyWithoutClaimingItHappened() {
        let row = try? XCTUnwrap(TranscriptionResultRow(state: completed(outcome: .ready)))
        XCTAssertEqual(row?.outcomeMessage, "Transcription ready")
        XCTAssertTrue(row?.offersCopy == true)
        XCTAssertEqual(row?.copyTitle, "Copy", "An untouched clipboard must read as an offer, not a receipt")
    }

    func testHistoryOnlyDestinationNeverImpliesAClipboardWrite() {
        let row = TranscriptionResultRow(state: completed(outcome: .savedToHistory))
        XCTAssertEqual(row?.outcomeMessage, "Saved to history")
        XCTAssertEqual(row?.copyTitle, "Copy")
    }

    func testAConfirmedCopyDoesNotOfferCopyAsThoughItHadNotHappened() {
        let row = TranscriptionResultRow(state: completed(outcome: .copied))
        XCTAssertEqual(row?.outcomeMessage, "Copied")
        XCTAssertEqual(row?.copyTitle, "Copy again")
    }

    func testSilenceOffersNoActionAndNoCount() {
        let row = TranscriptionResultRow(state: completed(outcome: .noSpeech, preview: "stale", wordCount: 9))
        XCTAssertEqual(row?.offersCopy, false)
        XCTAssertEqual(row?.offersOpen, false)
        XCTAssertNil(row?.preview, "A stale preview must not survive a silent outcome")
        XCTAssertNil(row?.wordCountText)
    }

    func testAnUnpublishedTranscriptOffersNoActionItCannotHonour() {
        // Keyboard handoffs keep their text in the nonce-scoped store, so nothing
        // is retrievable and the row carries no preview.
        let row = TranscriptionResultRow(state: completed(outcome: .ready, preview: "   "))
        XCTAssertEqual(row?.offersCopy, false)
        XCTAssertEqual(row?.offersOpen, false)
        XCTAssertNil(row?.preview)
        XCTAssertEqual(row?.outcomeMessage, "Transcription ready")
    }

    func testTheRowCarriesTheCompletionItsCopyActionMustAddress() {
        let row = TranscriptionResultRow(state: completed(outcome: .ready))
        XCTAssertEqual(row?.completionID, Self.completionID)
        XCTAssertEqual(row?.offersCopy, true)
    }

    func testARowThatCannotNameItsCompletionOffersNoCopy() {
        // Copy retrieves one specific completion's transcript. A payload with a
        // preview but no completion id — written before the id existed — cannot
        // prove which transcript it means, so it must not offer to copy one.
        let row = TranscriptionResultRow(state: completed(outcome: .ready, completionID: ""))
        XCTAssertEqual(row?.offersCopy, false, "Copy must never guess which completion it means")
        XCTAssertEqual(row?.preview, "Raw transcript")
        XCTAssertEqual(row?.offersOpen, true, "Open needs no id: it just opens the app")
    }

    func testWordCountTextIsSingularForOneWord() {
        XCTAssertEqual(TranscriptionResultRow(state: completed(outcome: .ready, wordCount: 1))?.wordCountText, "1 word")
        XCTAssertEqual(TranscriptionResultRow(state: completed(outcome: .ready, wordCount: 0))?.wordCountText, nil)
    }

    // MARK: - Preview construction

    func testPreviewTakesTheFirstNonBlankLine() {
        XCTAssertEqual(TranscriptionResultRow.preview(for: "\n  \nFirst line\nSecond line"), "First line")
        XCTAssertEqual(TranscriptionResultRow.preview(for: "  Trimmed  "), "Trimmed")
        XCTAssertEqual(TranscriptionResultRow.preview(for: "   \n\n "), "")
        XCTAssertEqual(TranscriptionResultRow.preview(for: ""), "")
    }

    func testPreviewIsTruncatedSoThePayloadStaysSmall() {
        let long = String(repeating: "a", count: 500)
        let preview = TranscriptionResultRow.preview(for: long)
        XCTAssertEqual(preview.count, TranscriptionResultRow.previewCharacterLimit + 1)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    // MARK: - Payload compatibility

    func testOlderPayloadsWithoutAPreviewDecodeToAnActionlessRow() throws {
        let legacy = Data("""
        {"status":"completed","lastSnippet":"Transcription complete","wordCount":3,"duration":4,
         "provider":"Apple Speech"}
        """.utf8)
        let state = try JSONDecoder().decode(TranscriptionActivityAttributes.ContentState.self, from: legacy)
        XCTAssertEqual(state.resultPreview, "")
        XCTAssertEqual(state.resultCompletionID, "")
        XCTAssertEqual(state.completionOutcome, .ready)
        let row = TranscriptionResultRow(state: state)
        XCTAssertEqual(row?.offersCopy, false, "An older payload proves nothing is retrievable")
        XCTAssertEqual(row?.offersOpen, false)
    }

    func testPreviewSurvivesACodableRoundTrip() throws {
        let state = completed(outcome: .copied, preview: "Hello there")
        let decoded = try JSONDecoder().decode(
            TranscriptionActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.resultPreview, "Hello there")
        XCTAssertEqual(decoded.resultCompletionID, Self.completionID)
    }
}
