import XCTest
@testable import SpeakCore

/// Covers the Handoff pointer payload (issue #1006).
final class TranscriptHandoffActivityTests: XCTestCase {

    private let pointer = TranscriptHandoffActivity.Pointer(
        entryID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        createdAt: Date(timeIntervalSince1970: 1_757_500_000.25),
        wordCount: 23,
        originPlatform: "ios"
    )

    func testPointerRoundTrips() {
        let userInfo = TranscriptHandoffActivity.userInfo(for: pointer)
        let restored = TranscriptHandoffActivity.pointer(from: userInfo)
        XCTAssertEqual(restored, pointer)
    }

    /// The whole reason the payload exists in this shape: it broadcasts a
    /// pointer, never the user's words.
    func testPayloadCarriesNoTranscriptText() {
        let userInfo = TranscriptHandoffActivity.userInfo(for: pointer)
        XCTAssertEqual(
            Set(userInfo.keys),
            [
                TranscriptHandoffActivity.Key.schemaVersion,
                TranscriptHandoffActivity.Key.entryID,
                TranscriptHandoffActivity.Key.createdAt,
                TranscriptHandoffActivity.Key.wordCount,
                TranscriptHandoffActivity.Key.originPlatform
            ]
        )
        for value in userInfo.values {
            XCTAssertFalse(value.contains(" "), "a pointer field should never hold prose: \(value)")
        }
    }

    func testUnknownSchemaDoesNotContinue() {
        var userInfo = TranscriptHandoffActivity.userInfo(for: pointer)
        userInfo[TranscriptHandoffActivity.Key.schemaVersion] = "99"
        XCTAssertNil(TranscriptHandoffActivity.pointer(from: userInfo))
    }

    func testMalformedPayloadsAreRejected() {
        XCTAssertNil(TranscriptHandoffActivity.pointer(from: nil))
        XCTAssertNil(TranscriptHandoffActivity.pointer(from: [:]))
        var userInfo = TranscriptHandoffActivity.userInfo(for: pointer)
        userInfo[TranscriptHandoffActivity.Key.entryID] = "not-a-uuid"
        XCTAssertNil(TranscriptHandoffActivity.pointer(from: userInfo))
    }

    func testMissingOptionalFieldsDegradeInsteadOfFailing() {
        var userInfo = TranscriptHandoffActivity.userInfo(for: pointer)
        userInfo.removeValue(forKey: TranscriptHandoffActivity.Key.wordCount)
        userInfo.removeValue(forKey: TranscriptHandoffActivity.Key.originPlatform)
        let restored = TranscriptHandoffActivity.pointer(from: userInfo)
        XCTAssertEqual(restored?.wordCount, 0)
        XCTAssertEqual(restored?.originPlatform, "unknown")
        XCTAssertEqual(restored?.deviceName, "another device")
    }

    func testTitleNamesTheSourceDevice() {
        XCTAssertEqual(
            TranscriptHandoffActivity.title(for: pointer),
            "Transcript from iPhone \u{00B7} 23 words"
        )
        let watch = TranscriptHandoffActivity.Pointer(
            entryID: UUID(), createdAt: Date(), wordCount: 1, originPlatform: "watchos"
        )
        XCTAssertEqual(
            TranscriptHandoffActivity.title(for: watch),
            "Transcript from Apple Watch \u{00B7} 1 word"
        )
    }
}
