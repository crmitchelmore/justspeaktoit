import SpeakCore
import XCTest

/// The prompt pair and reply handling every downloaded cleanup model shares (issue #1650).
final class LocalCleanupPromptTests: XCTestCase {
    func testSystemPrompt_extendsTheUsersCleanupPromptWithTheConstraintOnce() {
        let custom = TranscriptCleanupPolicy.baseSystemPrompt + "\nPut one full stop after each word."
        let prompt = LocalCleanupPrompt.systemPrompt(custom)

        XCTAssertTrue(prompt.hasPrefix(custom))
        XCTAssertEqual(prompt.components(separatedBy: LocalCleanupPrompt.engineConstraint).count, 2)
        XCTAssertEqual(
            LocalCleanupPrompt.explicitSystemPrompt("Translate to French."),
            "Translate to French.\n\n" + LocalCleanupPrompt.engineConstraint
        )
    }

    func testUserMessage_carriesTheTranscriptNotThePrompt() {
        let message = LocalCleanupPrompt.userMessage(transcript: "hello there")

        XCTAssertTrue(message.contains("hello there"))
        XCTAssertFalse(message.contains(LocalCleanupPrompt.engineConstraint))
    }

    func testIsEmpty_treatsBlankAndBlankAudioMarkerAsNothingToClean() {
        XCTAssertTrue(LocalCleanupPrompt.isEmpty("  \n"))
        XCTAssertTrue(LocalCleanupPrompt.isEmpty(" [BLANK_AUDIO] "))
        XCTAssertFalse(LocalCleanupPrompt.isEmpty("hi"))
    }

    func testReplyHandling_detectsThinkingAndUnwrapsOnlyAnExactTranscriptObject() {
        XCTAssertTrue(LocalCleanupPrompt.containsThinking("<think>hmm</think>Hi."))
        XCTAssertFalse(LocalCleanupPrompt.containsThinking("Hi."))
        XCTAssertEqual(LocalCleanupPrompt.strippingThinking("<think>hmm</think> Hi."), "Hi.")
        XCTAssertEqual(LocalCleanupPrompt.unwrappedReply(#" {"transcript": " Hi. "} "#), "Hi.")
        let extraKeys = #"{"transcript":"Hi.","x":1}"#
        XCTAssertEqual(LocalCleanupPrompt.unwrappedReply(extraKeys), extraKeys)
    }
}
