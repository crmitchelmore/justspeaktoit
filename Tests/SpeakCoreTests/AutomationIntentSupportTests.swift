import XCTest

@testable import SpeakCore

final class AutomationIntentSupportTests: XCTestCase {
    // MARK: - Audio file validation

    func testValidatedAudioExtension_acceptsSupportedExtensionsCaseInsensitively() throws {
        XCTAssertEqual(try AutomationIntentSupport.validatedAudioExtension(forFilename: "memo.m4a"), "m4a")
        XCTAssertEqual(try AutomationIntentSupport.validatedAudioExtension(forFilename: "Memo.M4A"), "m4a")
        XCTAssertEqual(try AutomationIntentSupport.validatedAudioExtension(forFilename: "take 2.WAV"), "wav")
        XCTAssertEqual(
            try AutomationIntentSupport.validatedAudioExtension(forFilename: "nested.name.mp3"),
            "mp3"
        )
    }

    func testValidatedAudioExtension_rejectsMissingExtension() {
        XCTAssertThrowsError(
            try AutomationIntentSupport.validatedAudioExtension(forFilename: "recording")
        ) { error in
            XCTAssertEqual(
                error as? AutomationIntentSupport.AudioFileValidationError,
                .missingExtension(filename: "recording")
            )
        }
    }

    func testValidatedAudioExtension_rejectsUnsupportedExtension() {
        XCTAssertThrowsError(
            try AutomationIntentSupport.validatedAudioExtension(forFilename: "notes.pdf")
        ) { error in
            XCTAssertEqual(
                error as? AutomationIntentSupport.AudioFileValidationError,
                .unsupportedType(fileExtension: "pdf")
            )
        }
    }

    func testValidateAudioFileSize_acceptsSizesUpToTheLimit() throws {
        XCTAssertNoThrow(try AutomationIntentSupport.validateAudioFileSize(0))
        XCTAssertNoThrow(try AutomationIntentSupport.validateAudioFileSize(1_024))
        XCTAssertNoThrow(
            try AutomationIntentSupport.validateAudioFileSize(AutomationIntentSupport.maximumAudioFileBytes)
        )
    }

    func testValidateAudioFileSize_rejectsSizesOverTheLimit() {
        let oversized = AutomationIntentSupport.maximumAudioFileBytes + 1
        XCTAssertThrowsError(
            try AutomationIntentSupport.validateAudioFileSize(oversized)
        ) { error in
            XCTAssertEqual(
                error as? AutomationIntentSupport.AudioFileValidationError,
                .fileTooLarge(
                    byteCount: oversized,
                    limit: AutomationIntentSupport.maximumAudioFileBytes
                )
            )
        }
    }

    func testAudioFileValidationErrors_haveDescriptions() {
        let missing = AutomationIntentSupport.AudioFileValidationError.missingExtension(filename: "x y")
        let unsupported = AutomationIntentSupport.AudioFileValidationError.unsupportedType(fileExtension: "pdf")
        let tooLarge = AutomationIntentSupport.AudioFileValidationError.fileTooLarge(
            byteCount: AutomationIntentSupport.maximumAudioFileBytes + 1,
            limit: AutomationIntentSupport.maximumAudioFileBytes
        )
        XCTAssertTrue(missing.errorDescription?.contains("x y") == true)
        XCTAssertTrue(unsupported.errorDescription?.contains("pdf") == true)
        XCTAssertTrue(unsupported.errorDescription?.contains("m4a") == true)
        XCTAssertTrue(tooLarge.errorDescription?.contains("limit") == true)
    }

    // MARK: - Polish prompt mapping

    func testPolishRequest_withoutCustomPromptUsesCleanupPolicy() {
        let request = AutomationIntentSupport.polishRequest(
            text: "hello world",
            customPrompt: nil,
            defaultSystemPrompt: TranscriptCleanupPolicy.systemPrompt()
        )
        XCTAssertEqual(request.systemPrompt, TranscriptCleanupPolicy.systemPrompt())
        XCTAssertEqual(request.userMessage, TranscriptCleanupPolicy.userMessage(transcript: "hello world"))
        XCTAssertFalse(request.isCustomPrompt)
    }

    func testPolishRequest_withBlankCustomPromptUsesCleanupPolicy() {
        let request = AutomationIntentSupport.polishRequest(
            text: "hello",
            customPrompt: "  \n ",
            defaultSystemPrompt: TranscriptCleanupPolicy.systemPrompt()
        )
        XCTAssertEqual(request.systemPrompt, TranscriptCleanupPolicy.systemPrompt())
        XCTAssertFalse(request.isCustomPrompt)
    }

    /// The caller's configured prompt — a custom base prompt, an output
    /// language, or a dictation profile override — must reach the model
    /// untouched, not be replaced by the stock cleanup policy.
    func testPolishRequest_withoutCustomPromptUsesInjectedDefaultVerbatim() {
        let configuredPrompt = "Reply only in British English. Keep the speaker's slang."
        let request = AutomationIntentSupport.polishRequest(
            text: "hello world",
            customPrompt: nil,
            defaultSystemPrompt: configuredPrompt
        )
        XCTAssertEqual(request.systemPrompt, configuredPrompt)
        XCTAssertNotEqual(request.systemPrompt, TranscriptCleanupPolicy.systemPrompt())
        XCTAssertEqual(request.userMessage, TranscriptCleanupPolicy.userMessage(transcript: "hello world"))
        XCTAssertFalse(request.isCustomPrompt)
    }

    /// A custom prompt replaces the cleanup contract entirely, and the request
    /// is flagged so local execution paths know they must honour the prompt
    /// pair verbatim instead of rebuilding the stock cleanup payload.
    func testPolishRequest_withCustomPromptPassesTextVerbatimAndFlagsCustom() {
        let request = AutomationIntentSupport.polishRequest(
            text: "long meeting notes",
            customPrompt: "  Summarise this in one sentence.  ",
            defaultSystemPrompt: TranscriptCleanupPolicy.systemPrompt()
        )
        XCTAssertEqual(request.systemPrompt, "Summarise this in one sentence.")
        XCTAssertEqual(request.userMessage, "long meeting notes")
        XCTAssertTrue(request.isCustomPrompt)
    }

    // MARK: - Transcript selection

    func testBestTranscript_prefersPolishedText() {
        XCTAssertEqual(
            AutomationIntentSupport.bestTranscript(raw: "raw words", polished: "Polished words."),
            "Polished words."
        )
    }

    func testBestTranscript_fallsBackToRawWhenPolishedIsBlank() {
        XCTAssertEqual(AutomationIntentSupport.bestTranscript(raw: "raw words", polished: "  "), "raw words")
        XCTAssertEqual(AutomationIntentSupport.bestTranscript(raw: "raw words", polished: nil), "raw words")
    }

    /// The Stop Dictation intents rely on this to reject duplicate/silent/
    /// failed stops: a blank transcript must yield nil, never empty text that
    /// a downstream Shortcut action would treat as success.
    func testBestTranscript_returnsNilWhenNothingUsable() {
        XCTAssertNil(AutomationIntentSupport.bestTranscript(raw: nil, polished: nil))
        XCTAssertNil(AutomationIntentSupport.bestTranscript(raw: " ", polished: ""))
        XCTAssertNil(AutomationIntentSupport.bestTranscript(raw: "", polished: nil))
        XCTAssertNil(AutomationIntentSupport.bestTranscript(raw: "\n\t ", polished: "  "))
    }
}
