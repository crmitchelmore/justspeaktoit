#if os(iOS)
import SpeakCore
import XCTest
@testable import SpeakiOSLib

final class TranscriptCleanupPolicyParityTests: XCTestCase {
    func testIOSDefaultAndEffectivePrompt_UseSharedCanonicalPolicy() {
        XCTAssertEqual(
            AppSettings.defaultPostProcessingPrompt,
            TranscriptCleanupPolicy.baseSystemPrompt
        )

        let prompt = iOSPostProcessingManager.effectiveSystemPrompt()

        XCTAssertTrue(prompt.hasPrefix(TranscriptCleanupPolicy.baseSystemPrompt))
        XCTAssertTrue(prompt.hasSuffix("Return only the cleaned transcript text."))
    }
}
#endif
