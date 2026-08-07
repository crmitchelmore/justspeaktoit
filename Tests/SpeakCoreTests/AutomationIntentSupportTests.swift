import XCTest

@testable import SpeakCore

final class AutomationIntentSupportTests: XCTestCase {
    // MARK: - Audio file validation

    func testAcceptsSupportedExtensionsCaseInsensitively() throws {
        XCTAssertEqual(try AutomationIntentSupport.validatedAudioExtension(forFilename: "memo.m4a"), "m4a")
        XCTAssertEqual(try AutomationIntentSupport.validatedAudioExtension(forFilename: "Memo.M4A"), "m4a")
        XCTAssertEqual(try AutomationIntentSupport.validatedAudioExtension(forFilename: "take 2.WAV"), "wav")
        XCTAssertEqual(
            try AutomationIntentSupport.validatedAudioExtension(forFilename: "nested.name.mp3"),
            "mp3"
        )
    }

    func testRejectsMissingExtension() {
        XCTAssertThrowsError(
            try AutomationIntentSupport.validatedAudioExtension(forFilename: "recording")
        ) { error in
            XCTAssertEqual(
                error as? AutomationIntentSupport.AudioFileValidationError,
                .missingExtension(filename: "recording")
            )
        }
    }

    func testRejectsUnsupportedExtension() {
        XCTAssertThrowsError(
            try AutomationIntentSupport.validatedAudioExtension(forFilename: "notes.pdf")
        ) { error in
            XCTAssertEqual(
                error as? AutomationIntentSupport.AudioFileValidationError,
                .unsupportedType(fileExtension: "pdf")
            )
        }
    }

    func testValidationErrorsHaveDescriptions() {
        let missing = AutomationIntentSupport.AudioFileValidationError.missingExtension(filename: "x y")
        let unsupported = AutomationIntentSupport.AudioFileValidationError.unsupportedType(fileExtension: "pdf")
        XCTAssertTrue(missing.errorDescription?.contains("x y") == true)
        XCTAssertTrue(unsupported.errorDescription?.contains("pdf") == true)
        XCTAssertTrue(unsupported.errorDescription?.contains("m4a") == true)
    }

    // MARK: - Polish prompt mapping

    func testPolishRequestWithoutCustomPromptUsesCleanupPolicy() {
        let request = AutomationIntentSupport.polishRequest(text: "hello world", customPrompt: nil)
        XCTAssertEqual(request.systemPrompt, TranscriptCleanupPolicy.systemPrompt())
        XCTAssertEqual(request.userMessage, TranscriptCleanupPolicy.userMessage(transcript: "hello world"))
    }

    func testPolishRequestWithBlankCustomPromptUsesCleanupPolicy() {
        let request = AutomationIntentSupport.polishRequest(text: "hello", customPrompt: "  \n ")
        XCTAssertEqual(request.systemPrompt, TranscriptCleanupPolicy.systemPrompt())
    }

    func testPolishRequestWithCustomPromptPassesTextVerbatim() {
        let request = AutomationIntentSupport.polishRequest(
            text: "long meeting notes",
            customPrompt: "  Summarise this in one sentence.  "
        )
        XCTAssertEqual(request.systemPrompt, "Summarise this in one sentence.")
        XCTAssertEqual(request.userMessage, "long meeting notes")
    }

    // MARK: - Transcript selection

    func testBestTranscriptPrefersPolishedText() {
        XCTAssertEqual(
            AutomationIntentSupport.bestTranscript(raw: "raw words", polished: "Polished words."),
            "Polished words."
        )
    }

    func testBestTranscriptFallsBackToRawWhenPolishedIsBlank() {
        XCTAssertEqual(AutomationIntentSupport.bestTranscript(raw: "raw words", polished: "  "), "raw words")
        XCTAssertEqual(AutomationIntentSupport.bestTranscript(raw: "raw words", polished: nil), "raw words")
    }

    func testBestTranscriptReturnsNilWhenNothingUsable() {
        XCTAssertNil(AutomationIntentSupport.bestTranscript(raw: nil, polished: nil))
        XCTAssertNil(AutomationIntentSupport.bestTranscript(raw: " ", polished: ""))
    }
}
