import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopVoiceSourceMessageTests: XCTestCase {
    func testNativeMessage_PreservesImmutableSourceAndDistinctOpaqueResultOwnership() throws {
        let history = UUID().uuidString
        let source = try VoiceOutputSourceSnapshot(
            source: .history, text: "Synthetic source.", recordID: UUID(uuidString: history)
        )
        XCTAssertEqual(try DesktopVoiceSourceMessage(
            action: 115, source: 0, text: source.text, record: history, path: "2"
        ), .event(.voiceGenerate(source, options: .init(autoPlay: false, saveToRecordings: true))))
        XCTAssertEqual(try DesktopVoiceSourceMessage(
            action: 116, source: 0, text: "", record: "opaque-result", path: ""
        ), .event(.voiceGeneratedPlay("opaque-result")))
        XCTAssertEqual(try DesktopVoiceSourceMessage(
            action: 113, source: 4, text: "", record: "opaque-import", path: "synthetic.txt"
        ), .event(.voiceImport(path: "synthetic.txt", requestID: "opaque-import")))
        XCTAssertEqual(try DesktopVoiceSourceMessage(
            action: 118, source: 1, text: "", record: "", path: ""
        ), .preferences(.init(autoPlay: true, saveToRecordings: false)))
    }

    func testNativeMessage_RejectsUnsupportedSelectionEmptyInputAndInvalidActionsOrOptions() {
        let cases: [InvalidMessage] = [
            .init(action: 110, source: 3, text: "Synthetic external selection", path: ""),
            .init(action: 115, source: 1, text: " ", path: "0"),
            .init(action: 115, source: 1, text: "Synthetic text", path: "4"),
            .init(action: 118, source: 4, text: "", path: ""),
            .init(action: 119, source: 1, text: "Synthetic text", path: "")
        ]
        for message in cases {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(
                action: message.action, source: message.source, text: message.text, record: "", path: message.path
            ))
        }
    }

    private struct InvalidMessage {
        let action: Int32
        let source: Int32
        let text: String
        let path: String
    }
}
