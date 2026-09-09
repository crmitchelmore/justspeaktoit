import Foundation
import XCTest

@testable import SpeakCore

final class TranscriptionCompletionOutcomeTests: XCTestCase {
    func testOutcomeMessages_DescribeOnlyTheConfirmedEffect() {
        let messages: [TranscriptionCompletionOutcome: String] = [
            .ready: "Transcription ready",
            .copied: "Copied",
            .savedToHistory: "Saved to history",
            .noSpeech: "No speech detected"
        ]
        XCTAssertEqual(messages.count, TranscriptionCompletionOutcome.allCases.count)
        for (outcome, message) in messages {
            XCTAssertEqual(outcome.message, message)
        }
    }

    func testUnconfirmedCompletion_DoesNotPromiseDeliveryOrPersistence() {
        XCTAssertEqual(.unconfirmed(transcript: "Raw transcript"), TranscriptionCompletionOutcome.ready)
        XCTAssertEqual(.unconfirmed(transcript: "Polished transcript"), TranscriptionCompletionOutcome.ready)
    }

    func testEmptyCompletion_NeverClaimsCopiedOrSaved() {
        for text in ["", " ", "\n\t", "\u{00A0}"] {
            XCTAssertEqual(.unconfirmed(transcript: text), TranscriptionCompletionOutcome.noSpeech)
        }
    }

    func testLegacyContentWithoutOutcome_DecodesAsNeutralAndPreservesFields() throws {
        let legacy = Data("""
        {"status":"completed","lastSnippet":"Old result","wordCount":12,
         "duration":34,"provider":"Apple Speech","errorMessage":"Old error"}
        """.utf8)
        let state = try JSONDecoder().decode(TranscriptionActivityAttributes.ContentState.self, from: legacy)
        XCTAssertEqual(state.completionOutcome, .ready)
        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(state.lastSnippet, "Old result")
        XCTAssertEqual(state.wordCount, 12)
        XCTAssertEqual(state.duration, 34)
        XCTAssertEqual(state.provider, "Apple Speech")
        XCTAssertEqual(state.errorMessage, "Old error")
    }

    func testLegacyInitialiser_DefaultsToNeutral() {
        let state = TranscriptionActivityAttributes.ContentState(status: .completed, wordCount: 12)
        XCTAssertEqual(state.completionOutcome, .ready)
    }

    func testNewContent_RoundTripsEveryOutcome() throws {
        for outcome in TranscriptionCompletionOutcome.allCases {
            let state = TranscriptionActivityAttributes.ContentState(
                status: .completed,
                lastSnippet: "Raw transcript",
                wordCount: 2,
                duration: 3,
                completionOutcome: outcome
            )
            let encoded = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(TranscriptionActivityAttributes.ContentState.self, from: encoded)
            XCTAssertEqual(decoded, state)
        }
    }

    func testInvalidOutcome_DoesNotSilentlyBecomeASuccessClaim() {
        let invalid = Data("""
        {"status":"completed","lastSnippet":"","wordCount":1,"duration":2,
         "provider":"Apple Speech","completionOutcome":"inserted"}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TranscriptionActivityAttributes.ContentState.self, from: invalid))
    }
}
