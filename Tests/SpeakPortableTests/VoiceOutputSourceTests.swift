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
}
