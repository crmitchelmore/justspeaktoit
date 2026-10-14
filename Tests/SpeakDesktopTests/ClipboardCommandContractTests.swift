import SpeakCore
import XCTest

final class ClipboardCommandContractTests: XCTestCase {
    @MainActor
    func testCanonicalExpansionKeepsWholePhraseAndLongestTriggerSemantics() async {
        let processor = makeProcessor(customTriggers: "paste, copy pasta now", clipboard: "SYNTHETIC")
        XCTAssertEqual(processor.process("(paste clipboard), thanks"), "(SYNTHETIC), thanks")
        XCTAssertEqual(processor.process("copy pasta now then insert clipboard"), "SYNTHETIC then SYNTHETIC")
        XCTAssertEqual(processor.process("copypastas and pasted words"), "copypastas and pasted words")
    }

    @MainActor
    func testAbsentAndEmptyClipboardLeaveRecognizedCommandsUnchanged() async {
        for clipboard: String? in [nil, ""] {
            let processor = makeProcessor(clipboard: clipboard)
            XCTAssertEqual(processor.process("please copy pasta here"), "please copy pasta here")
        }
    }

    @MainActor
    func testDisabledCommandsNeverReadClipboard() async {
        var reads = 0
        let processor = VoiceCommandProcessor(configuration: .init(
            isEnabled: { false }, customTriggers: { "" },
            clipboardText: { reads += 1; return "SYNTHETIC" }
        ))
        XCTAssertEqual(processor.process("copy pasta"), "copy pasta")
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testEnabledProcessorDoesNotReadForOrdinaryText() async {
        var reads = 0
        let processor = VoiceCommandProcessor(configuration: .init(
            isEnabled: { true }, customTriggers: { "" },
            clipboardText: { reads += 1; return "SYNTHETIC" }
        ))
        XCTAssertEqual(
            processor.process("ordinary transcript without a command"), "ordinary transcript without a command"
        )
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testRecognitionUsesCanonicalTriggersWithoutReadingClipboard() async {
        var reads = 0
        let policy = ClipboardVoiceCommandPolicy(isEnabled: true, customTriggers: "paste")
        let processor = VoiceCommandProcessor(configuration: .init(
            policy: policy, clipboardText: { reads += 1; return "SYNTHETIC" }
        ))
        XCTAssertTrue(processor.recognizesClipboardCommand(in: "(paste clipboard)"))
        XCTAssertFalse(processor.recognizesClipboardCommand(in: "pasted words"))
        XCTAssertFalse(processor.recognizesClipboardCommand(in: "ordinary text"))
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testCanonicalRecursiveExpansionHasABoundedDepth() async {
        var reads = 0
        let processor = VoiceCommandProcessor(configuration: .init(
            isEnabled: { true }, customTriggers: { "" },
            clipboardText: { reads += 1; return "copy pasta" }
        ))
        XCTAssertEqual(processor.process("copy pasta"), "copy pasta")
        XCTAssertEqual(reads, 10)
    }

    @MainActor
    private func makeProcessor(
        customTriggers: String = "", clipboard: String?
    ) -> VoiceCommandProcessor {
        VoiceCommandProcessor(configuration: .init(
            isEnabled: { true }, customTriggers: { customTriggers }, clipboardText: { clipboard }
        ))
    }
}
