import AppKit
import XCTest

@testable import SpeakApp

final class TextOutputTests: XCTestCase {
  @MainActor
  func testOutput_emptyTranscript_PreservesClipboard() {
    let suiteName = "com.speakapp.text-output-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
    defer {
      pasteboard.clearContents()
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    pasteboard.clearContents()
    pasteboard.setString("existing clipboard", forType: .string)

    let output = PasteTextOutput(
      permissionsManager: PermissionsManager(statusProvider: { _ in .denied }),
      appSettings: AppSettings(defaults: defaults),
      pasteboard: pasteboard
    )

    let result = output.output(text: " \n\t ")

    XCTAssertEqual(result.method, .none)
    XCTAssertNil(result.error)
    XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
  }

  @MainActor
  func testHasDeliverableText_emptyAndWhitespace_ReturnsFalse() {
    XCTAssertFalse(PasteTextOutput.hasDeliverableText(""))
    XCTAssertFalse(PasteTextOutput.hasDeliverableText(" \n\t "))
  }

  @MainActor
  func testHasDeliverableText_transcript_ReturnsTrue() {
    XCTAssertTrue(PasteTextOutput.hasDeliverableText("Foreground recording works."))
  }
}
