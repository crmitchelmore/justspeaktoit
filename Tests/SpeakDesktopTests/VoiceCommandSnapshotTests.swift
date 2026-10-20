import Foundation
import SpeakCore
import XCTest

final class VoiceCommandSnapshotTests: XCTestCase {
    @MainActor
    func testSnapshotAndAppleWrapperShareEstablishedMatchingAndDepthRules() async {
        func assertExpansion(
            _ text: String, custom: String = "", clipboard: String? = "PASTED",
            enabled: Bool = true, expected: String
        ) {
            let processor = VoiceCommandProcessor(configuration: .init(
                isEnabled: { enabled }, customTriggers: { custom }, clipboardText: { clipboard }
            ))
            XCTAssertEqual(processor.process(text), expected)
            XCTAssertEqual(VoiceCommandProcessor.process(
                text, enabled: enabled, customTriggers: custom, clipboardText: clipboard
            ), expected)
        }
        assertExpansion("please copy pasta here", expected: "please PASTED here")
        assertExpansion("paste clipboard", custom: "paste", expected: "PASTED")
        assertExpansion("copy pasta now", custom: "copy pasta now", expected: "PASTED")
        assertExpansion("note then copy pasta", custom: "note", expected: "PASTED then PASTED")
        assertExpansion("copypastas and pasted", custom: "paste", expected: "copypastas and pasted")
        assertExpansion("(Copy Pasta), thanks", custom: "Copy Pasta, COPY PASTA", expected: "(PASTED), thanks")
        assertExpansion("copy pasta", clipboard: "", expected: "copy pasta")
        assertExpansion("copy pasta", clipboard: nil, expected: "copy pasta")
        assertExpansion("copy pasta", enabled: false, expected: "copy pasta")
        assertExpansion("copy pasta", clipboard: "copy pasta!", expected: "copy pasta!!!!!!!!!!")
        assertExpansion("hello", custom: " , , ", expected: "hello")
        XCTAssertFalse(VoiceCommandProcessor.containsClipboardCommand(in: "copypastas", customTriggers: ""))
        XCTAssertTrue(VoiceCommandProcessor.containsClipboardCommand(
            in: "(MY SNIPPET)", customTriggers: "my snippet"
        ))
    }

    func testSnapshotProcessingDoesNotRequireTheMainActor() async throws {
        let result = await Task.detached {
            VoiceCommandProcessor.process(
                "paste clipboard", enabled: true, customTriggers: "paste", clipboardText: "OK"
            )
        }.value
        XCTAssertEqual(result, "OK")
    }
}
