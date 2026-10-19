import Foundation
import XCTest
import SpeakCore

final class VoiceOutputSourceTests: XCTestCase {
    func testSources_HistoryDefaultAndClipboardNeverSubstitutesForSelection() throws {
        XCTAssertEqual(VoiceOutputSource.allCases.first, .history)
        let record = UUID()
        let history = try VoiceOutputSourceSnapshot(source: .history, text: "Synthetic history", recordID: record)
        XCTAssertEqual(history.recordID, record)
        let typed = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic typed", recordID: record)
        XCTAssertNil(typed.recordID)
        XCTAssertThrowsError(try VoiceOutputSourceSnapshot(source: .externalSelection, text: "clipboard text"))
        XCTAssertThrowsError(try VoiceOutputSourceSnapshot(source: .history, text: "No owner"))
    }

    func testEmptyAndOversizedSources_AreRefusedBeforeProviderWork() {
        for text in ["", " \n\t ", String(repeating: "x", count: 100_001), "null\0text"] {
            XCTAssertThrowsError(try VoiceOutputSourceSnapshot(source: .clipboard, text: text))
        }
    }

    func testCapturedSelection_PreservesProvenanceThroughPronunciationReplacement() throws {
        let source = try VoiceOutputSourceSnapshot(capturedExternalSelection: "Selected name")
        let prepared = try source.replacingText("Pronounced name")
        XCTAssertEqual(source.text, "Selected name")
        XCTAssertEqual(prepared.text, "Pronounced name")
        XCTAssertEqual(prepared.source, .externalSelection)
        XCTAssertNil(prepared.recordID)
        XCTAssertThrowsError(try VoiceOutputSourceSnapshot(source: .externalSelection, text: prepared.text))
        XCTAssertThrowsError(try prepared.replacingText(""))
        XCTAssertThrowsError(try prepared.replacingText("before\0after"))
    }

    func testCapturedSelection_UsesExactCanonicalUnicodeScalarLimit() throws {
        for character in ["x", "\u{1F642}"] {
            let maximum = String(repeating: character, count: VoiceOutputSourceSnapshot.maximumCharacters)
            XCTAssertEqual(try VoiceOutputSourceSnapshot(capturedExternalSelection: maximum).text, maximum)
            XCTAssertThrowsError(try VoiceOutputSourceSnapshot(capturedExternalSelection: maximum + character))
        }
        for text in ["", " \n\t ", "before\0after"] {
            XCTAssertThrowsError(try VoiceOutputSourceSnapshot(capturedExternalSelection: text))
        }
    }

    func testSourceTextReplacement_PreservesHistoryOwnerAndRevalidatesBounds() throws {
        let record = UUID()
        let history = try VoiceOutputSourceSnapshot(source: .history, text: "Original", recordID: record)
        let prepared = try history.replacingText("Replacement")
        XCTAssertEqual(prepared.source, .history)
        XCTAssertEqual(prepared.recordID, record)
        XCTAssertThrowsError(try history.replacingText(String(
            repeating: "x", count: VoiceOutputSourceSnapshot.maximumCharacters + 1)))
    }
}
