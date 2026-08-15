import XCTest

@testable import SpeakCore

@MainActor
final class VoiceCommandProcessorTests: XCTestCase {
  private func makeProcessor(
    customTriggers: String = "",
    clipboard: String? = "PASTED",
    isEnabled: Bool = true
  ) -> VoiceCommandProcessor {
    VoiceCommandProcessor(
      configuration: VoiceCommandProcessor.Configuration(
        isEnabled: { isEnabled },
        customTriggers: { customTriggers },
        clipboardText: { clipboard }
      )
    )
  }

  func testBuiltInTrigger_expandsToClipboardContent() {
    let processor = makeProcessor()

    XCTAssertEqual(processor.process("please copy pasta here"), "please PASTED here")
  }

  func testDisabledProcessor_leavesTextUnchanged() {
    let processor = makeProcessor(isEnabled: false)

    XCTAssertEqual(processor.process("please copy pasta here"), "please copy pasta here")
  }

  func testEmptyClipboard_leavesTextUnchanged() {
    let processor = makeProcessor(clipboard: "")

    XCTAssertEqual(processor.process("please copy pasta here"), "please copy pasta here")
  }

  func testCustomTriggerShadowingBuiltIn_expandsTheLongestPhrase() {
    let processor = makeProcessor(customTriggers: "paste")

    XCTAssertEqual(processor.process("paste clipboard"), "PASTED")
  }

  func testCustomTriggerOrder_doesNotChangeTheResult() {
    let leadingCustom = makeProcessor(customTriggers: "paste, insert")
    let trailingCustom = makeProcessor(customTriggers: "insert, paste")

    XCTAssertEqual(leadingCustom.process("paste clipboard"), "PASTED")
    XCTAssertEqual(trailingCustom.process("paste clipboard"), "PASTED")
  }

  func testCustomTriggerLongerThanBuiltIn_winsAtTheSamePosition() {
    let processor = makeProcessor(customTriggers: "copy pasta now")

    XCTAssertEqual(processor.process("copy pasta now"), "PASTED")
  }

  func testRepeatedRuns_produceTheSameResult() {
    let processor = makeProcessor(customTriggers: "paste, clipboard, paste clip")

    let results = Set((0..<25).map { _ in processor.process("paste clipboard") })

    XCTAssertEqual(results, ["PASTED"])
  }

  func testEarliestTriggerWins_whenTwoPhrasesAppear() {
    let processor = makeProcessor(customTriggers: "note")

    XCTAssertEqual(processor.process("note then copy pasta"), "PASTED then PASTED")
  }

  func testCaseVariedDuplicateTriggers_expandOnce() {
    let processor = makeProcessor(customTriggers: "Copy Pasta, copy pasta, COPY PASTA")

    XCTAssertEqual(processor.process("say Copy Pasta twice"), "say PASTED twice")
  }

  func testTriggerInsideALongerWord_doesNotExpand() {
    let processor = makeProcessor(customTriggers: "paste")

    XCTAssertEqual(processor.process("copypastas and pasted text"), "copypastas and pasted text")
  }

  func testTriggerNextToPunctuation_expands() {
    let processor = makeProcessor()

    XCTAssertEqual(processor.process("(copy pasta), thanks"), "(PASTED), thanks")
  }

  func testMultipleTriggers_allExpand() {
    let processor = makeProcessor(customTriggers: "paste")

    XCTAssertEqual(
      processor.process("copy pasta then insert clipboard then paste"),
      "PASTED then PASTED then PASTED"
    )
  }

  func testClipboardContentContainingATrigger_terminatesWithBoundedExpansion() {
    let processor = makeProcessor(clipboard: "copy pasta")

    XCTAssertEqual(processor.process("copy pasta"), "copy pasta")
  }
}
