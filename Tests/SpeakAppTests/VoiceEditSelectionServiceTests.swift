import AppKit
import XCTest

@testable import SpeakApp

/// Selection capture must produce an anchor the replacement step can verify,
/// restore the user's clipboard exactly, and edit the last dictation only at
/// the range it was inserted into (issue #673).
@MainActor
final class VoiceEditSelectionServiceTests: XCTestCase {
  private typealias Support = VoiceEditTestSupport

  // MARK: - Accessibility selection

  func testCapture_accessibilitySelection_anchorsToVerifiedRange() async throws {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    let harness = makeHarness(field: field)

    let captured = await harness.service.capture()
    let capture = try XCTUnwrap(captured)

    XCTAssertEqual(capture.selection, .init(text: "quick", source: .accessibility))
    XCTAssertEqual(capture.anchor, VoiceEditAnchor(text: "quick", range: Support.range(4, 5)))
    XCTAssertTrue(capture.field?.isSameField(as: field) ?? false)
    XCTAssertEqual(harness.copyRequests, 0, "A direct selection read needs no ⌘C")
  }

  func testCapture_dropsRangeThatDisagreesWithTheFieldValue() async throws {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 0, length: 3))
    field.selectedTextOverride = "quick"
    let harness = makeHarness(field: field)

    let captured = await harness.service.capture()
    let capture = try XCTUnwrap(captured)

    XCTAssertEqual(capture.selection.text, "quick")
    XCTAssertNil(capture.anchor.range, "A range that does not cover the selected text is not an anchor")
  }

  func testCapture_withoutAccessibilityPermission_doesNotReadTheField() async throws {
    let field = FakeVoiceEditField(value: "secret text", selection: CFRange(location: 0, length: 6))
    let harness = makeHarness(field: field, accessibilityGranted: false, copiedText: "copied text")

    let captured = await harness.service.capture()
    let capture = try XCTUnwrap(captured)

    XCTAssertEqual(capture.selection, .init(text: "copied text", source: .clipboard))
    XCTAssertNil(capture.field)
    XCTAssertNil(capture.anchor.range)
  }

  // MARK: - Clipboard capture

  func testCapture_clipboardFallback_restoresEveryPasteboardTypeAfterwards() async throws {
    let field = FakeVoiceEditField(value: "no selection here", selection: nil)
    let harness = makeHarness(field: field, copiedText: "copied words")
    let userItem = NSPasteboardItem()
    userItem.setString("user text", forType: .string)
    userItem.setData(Data("{\\rtf1 user}".utf8), forType: .rtf)
    harness.pasteboard.clearContents()
    harness.pasteboard.writeObjects([userItem])

    let captured = await harness.service.capture()
    let capture = try XCTUnwrap(captured)

    XCTAssertEqual(capture.selection, .init(text: "copied words", source: .clipboard))
    XCTAssertEqual(harness.copyRequests, 1)
    let restored = try XCTUnwrap(harness.pasteboard.pasteboardItems?.first)
    XCTAssertEqual(restored.string(forType: .string), "user text")
    XCTAssertEqual(restored.data(forType: .rtf), Data("{\\rtf1 user}".utf8))
  }

  func testCapture_clipboardFallbackThatCopiesNothing_restoresPasteboardAndFallsThrough() async {
    let field = FakeVoiceEditField(value: "nothing selected", selection: nil)
    let harness = makeHarness(field: field, copiedText: nil)
    harness.pasteboard.clearContents()
    harness.pasteboard.setString("user text", forType: .string)

    let capture = await harness.service.capture()

    XCTAssertNil(capture)
    XCTAssertEqual(harness.pasteboard.string(forType: .string), "user text")
  }

  // MARK: - Last dictation

  func testCapture_lastInsertion_usesRecordedRangeNotTextSearch() async throws {
    // The same words occur twice; only the second occurrence was dictated.
    let field = FakeVoiceEditField(value: "hello world hello", selection: nil)
    let harness = makeHarness(field: field, copiedText: nil)
    harness.records.record(
      InsertionRecord(target: Support.runningTarget(), range: Support.range(12, 5), text: "hello", recordedAt: Date())
    )

    let captured = await harness.service.capture()
    let capture = try XCTUnwrap(captured)

    XCTAssertEqual(capture.selection, .init(text: "hello", source: .lastInsertion))
    XCTAssertEqual(capture.anchor.range, Support.range(12, 5))
  }

  func testCapture_lastInsertion_rejectsRangeWhoseTextChanged() async {
    let field = FakeVoiceEditField(value: "hello world HELLO", selection: nil)
    let harness = makeHarness(field: field, copiedText: nil)
    harness.records.record(
      InsertionRecord(target: Support.runningTarget(), range: Support.range(12, 5), text: "hello", recordedAt: Date())
    )

    let capture = await harness.service.capture()

    XCTAssertNil(capture, "Edited text at the recorded range must not be treated as the last dictation")
  }

  func testCapture_lastInsertion_rejectsWhenAnotherFieldHasFocus() async {
    let field = FakeVoiceEditField(value: "hello world hello", selection: nil)
    let harness = makeHarness(field: field, copiedText: nil)
    harness.resolver.focused = FakeVoiceEditField(value: "hello world hello", selection: nil)
    harness.records.record(
      InsertionRecord(target: Support.runningTarget(), range: Support.range(12, 5), text: "hello", recordedAt: Date())
    )

    let capture = await harness.service.capture()

    XCTAssertNil(capture)
  }

  func testCapture_lastInsertion_rejectsRecordFromAnotherApp() async {
    let field = FakeVoiceEditField(value: "hello world hello", selection: nil)
    let harness = makeHarness(field: field, copiedText: nil)
    harness.records.record(
      InsertionRecord(target: Support.goneTarget(), range: Support.range(12, 5), text: "hello", recordedAt: Date())
    )

    let capture = await harness.service.capture()

    XCTAssertNil(capture)
  }

  func testCapture_withoutRecordOrSelection_returnsNil() async {
    let field = FakeVoiceEditField(value: "hello", selection: nil)
    let harness = makeHarness(field: field, copiedText: nil)

    let capture = await harness.service.capture()

    XCTAssertNil(capture)
  }

  // MARK: - Helpers

  @MainActor
  private final class Harness {
    let service: VoiceEditSelectionService
    let resolver: FakeVoiceEditFieldResolver
    let records: InsertionRecordStore
    let pasteboard: NSPasteboard
    private(set) var copyRequests = 0

    init(field: FakeVoiceEditField, accessibilityGranted: Bool, copiedText: String?) {
      let resolver = FakeVoiceEditFieldResolver(captured: field)
      let records = InsertionRecordStore()
      let pasteboard = Support.makePasteboard()
      self.resolver = resolver
      self.records = records
      self.pasteboard = pasteboard
      var countCopies: (() -> Void)?
      self.service = VoiceEditSelectionService(
        permissionsManager: PermissionsManager(statusProvider: { _ in accessibilityGranted ? .granted : .denied }),
        insertionRecords: records,
        fieldResolver: resolver,
        pasteboard: pasteboard,
        targetProvider: { Support.runningTarget() },
        copyShortcut: { _ in
          countCopies?()
          guard let copiedText else { return true }
          pasteboard.clearContents()
          pasteboard.setString(copiedText, forType: .string)
          return true
        },
        copySettleDelay: .milliseconds(1)
      )
      countCopies = { [weak self] in self?.copyRequests += 1 }
    }

    deinit {
      pasteboard.clearContents()
    }
  }

  private func makeHarness(
    field: FakeVoiceEditField,
    accessibilityGranted: Bool = true,
    copiedText: String? = nil
  ) -> Harness {
    Harness(field: field, accessibilityGranted: accessibilityGranted, copiedText: copiedText)
  }
}
