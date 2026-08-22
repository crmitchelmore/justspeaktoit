import AppKit
import XCTest

@testable import SpeakApp

/// Replacement must touch only the captured range, verify what it wrote, and
/// park the rewrite on the clipboard — never report "Edited" — whenever it
/// cannot (issue #673).
@MainActor
final class VoiceEditReplacementServiceTests: XCTestCase {
  private typealias Support = VoiceEditTestSupport

  // MARK: - Accessibility replacement

  func testReplace_intactAnchor_replacesTheCapturedRangeEvenAfterTheCaretMoved() async {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    let harness = makeHarness(field: field)
    let capture = harness.capture(text: "quick", range: Support.range(4, 5))
    // The user clicked to the end of the field while speaking.
    field.selection = CFRange(location: 19, length: 0)

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .replaced)
    XCTAssertEqual(field.value, "The slow brown fox")
    XCTAssertEqual(field.selectedTextWrites.count, 1)
    XCTAssertEqual(field.selectedTextWrites.first?.range.map(VoiceEditTextRange.init), Support.range(4, 5))
    XCTAssertEqual(harness.pasteRequests, 0)
  }

  func testReplace_editedAnchor_parksRewriteWithoutWriting() async {
    let field = FakeVoiceEditField(value: "The QUICK brown fox", selection: CFRange(location: 4, length: 5))
    let harness = makeHarness(field: field)
    let capture = harness.capture(text: "quick", range: Support.range(4, 5))

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .leftOnClipboard(.selectionChanged))
    XCTAssertEqual(field.value, "The QUICK brown fox")
    XCTAssertTrue(field.selectedTextWrites.isEmpty)
    XCTAssertEqual(harness.pasteboard.string(forType: .string), "slow")
    XCTAssertEqual(harness.pasteRequests, 0)
  }

  func testReplace_focusInAnotherField_parksRewriteWithoutWriting() async {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    let harness = makeHarness(field: field)
    harness.resolver.focused = FakeVoiceEditField(
      value: "The quick brown fox", selection: CFRange(location: 4, length: 5)
    )
    let capture = harness.capture(text: "quick", range: Support.range(4, 5))

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .leftOnClipboard(.selectionChanged))
    XCTAssertTrue(field.selectedTextWrites.isEmpty)
    XCTAssertEqual(harness.pasteRequests, 0)
  }

  func testReplace_targetGone_parksRewrite() async {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    let harness = makeHarness(field: field)
    let capture = harness.capture(text: "quick", range: Support.range(4, 5), target: Support.goneTarget())

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .leftOnClipboard(.targetUnavailable))
    XCTAssertTrue(field.selectedTextWrites.isEmpty)
    XCTAssertEqual(harness.pasteRequests, 0)
  }

  func testReplace_unverifiableField_parksRewrite() async {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    field.valueReadable = false
    field.selectionRangeReadable = false
    field.selectedTextReadable = false
    let harness = makeHarness(field: field)
    let capture = harness.capture(text: "quick", range: Support.range(4, 5))

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .leftOnClipboard(.selectionUnverifiable))
    XCTAssertTrue(field.selectedTextWrites.isEmpty)
    XCTAssertEqual(harness.pasteRequests, 0)
  }

  func testReplace_acceptedWriteThatDoesNotShow_parksWithoutPastingOnTop() async {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    field.transformOnWrite = { _ in "garbled" }
    let harness = makeHarness(field: field)
    let capture = harness.capture(text: "quick", range: Support.range(4, 5))

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .leftOnClipboard(.replacementUnverified))
    XCTAssertEqual(harness.pasteRequests, 0, "Pasting after an accepted write could only duplicate it")
    XCTAssertEqual(harness.pasteboard.string(forType: .string), "slow")
  }

  func testReplace_unreadableValueAfterAcceptedWrite_isTrusted() async {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    field.valueReadable = false
    let harness = makeHarness(field: field)
    let capture = harness.capture(text: "quick", range: Support.range(4, 5))

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .replaced)
    XCTAssertEqual(field.value, "The slow brown fox")
  }

  func testReplace_textOnlyAnchor_requiresTheSelectionToStillMatch() async {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    let harness = makeHarness(field: field)
    let capture = harness.capture(text: "quick", range: nil)

    let intact = await harness.service.replace(capture, with: "slow")
    XCTAssertEqual(intact, .replaced)
    XCTAssertEqual(field.value, "The slow brown fox")

    field.selection = CFRange(location: 0, length: 3)
    let moved = await harness.service.replace(harness.capture(text: "slow", range: nil), with: "fast")
    XCTAssertEqual(moved, .leftOnClipboard(.selectionChanged))
    XCTAssertEqual(field.value, "The slow brown fox")
  }

  // MARK: - Paste fallback

  #if !APP_STORE
  func testReplace_whenAccessibilityWriteIsRejected_pastesAndRestoresClipboard() async throws {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    field.setSelectedTextResult = .failure
    let harness = makeHarness(field: field)
    harness.pasteboard.clearContents()
    harness.pasteboard.setString("user clipboard", forType: .string)
    harness.onPaste = { [weak harness] in
      guard let pasted = harness?.pasteboard.string(forType: .string) else { return }
      field.setSelectedTextResult = .success
      field.simulatePaste(pasted)
    }
    let capture = harness.capture(text: "quick", range: Support.range(4, 5))

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .pasted)
    XCTAssertEqual(field.value, "The slow brown fox")
    XCTAssertEqual(harness.pasteRequests, 1)
    XCTAssertEqual(
      harness.pasteboard.string(forType: .string), "user clipboard",
      "A verified paste restores the clipboard"
    )
  }

  func testReplace_ignoredPaste_parksRewriteAndKeepsItOnClipboard() async {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    field.setSelectedTextResult = .failure
    let harness = makeHarness(field: field)
    harness.pasteboard.clearContents()
    harness.pasteboard.setString("user clipboard", forType: .string)
    let capture = harness.capture(text: "quick", range: Support.range(4, 5))

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .leftOnClipboard(.pasteUnverified))
    XCTAssertEqual(field.value, "The quick brown fox")
    XCTAssertEqual(harness.pasteRequests, 1)
    XCTAssertEqual(harness.pasteboard.string(forType: .string), "slow", "The rewrite stays available for a manual ⌘V")
  }

  func testReplace_pastePath_refusesWhenTheSelectionMoved() async {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    field.setSelectedRangeResult = .failure
    field.setSelectedTextResult = .failure
    field.selection = CFRange(location: 19, length: 0)
    let harness = makeHarness(field: field)
    let capture = harness.capture(text: "quick", range: Support.range(4, 5))

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .leftOnClipboard(.selectionChanged))
    XCTAssertEqual(harness.pasteRequests, 0, "⌘V would replace whatever is selected now, so it must not be posted")
  }

  func testReplace_withoutFieldAccess_parksInsteadOfPastingBlind() async {
    let harness = makeHarness(field: nil)
    let capture = VoiceEditSelectionService.Capture(
      selection: .init(text: "quick", source: .clipboard),
      target: Support.runningTarget(),
      field: nil,
      anchor: VoiceEditAnchor(text: "quick", range: nil)
    )

    let outcome = await harness.service.replace(capture, with: "slow")

    XCTAssertEqual(outcome, .leftOnClipboard(.selectionUnverifiable))
    XCTAssertEqual(harness.pasteRequests, 0)
    XCTAssertEqual(harness.pasteboard.string(forType: .string), "slow")
  }
  #endif

  func testLeaveOnClipboard_parksWithNoCaptureReason() {
    let harness = makeHarness(field: nil)

    XCTAssertEqual(harness.service.leaveOnClipboard("slow"), .leftOnClipboard(.noCapture))
    XCTAssertEqual(harness.pasteboard.string(forType: .string), "slow")
  }

  // MARK: - Helpers

  @MainActor
  private final class Harness {
    let service: VoiceEditReplacementService
    let resolver: FakeVoiceEditFieldResolver
    let pasteboard: NSPasteboard
    let field: FakeVoiceEditField?
    var onPaste: (() -> Void)?
    private(set) var pasteRequests = 0

    init(field: FakeVoiceEditField?) {
      let resolver = FakeVoiceEditFieldResolver(captured: field)
      let pasteboard = Support.makePasteboard()
      self.resolver = resolver
      self.pasteboard = pasteboard
      self.field = field
      var recordPaste: (() -> Void)?
      self.service = VoiceEditReplacementService(
        permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
        fieldResolver: resolver,
        pasteboard: pasteboard,
        pasteShortcut: { _ in
          recordPaste?()
          return true
        },
        accessibilityVerificationDelay: .milliseconds(1),
        pasteVerificationInterval: .milliseconds(1),
        pasteVerificationAttempts: 3
      )
      recordPaste = { [weak self] in
        self?.pasteRequests += 1
        self?.onPaste?()
      }
    }

    deinit {
      pasteboard.clearContents()
    }

    func capture(
      text: String,
      range: VoiceEditTextRange?,
      target: TextOutputTarget? = nil
    ) -> VoiceEditSelectionService.Capture {
      VoiceEditSelectionService.Capture(
        selection: .init(text: text, source: .accessibility),
        target: target ?? Support.runningTarget(),
        field: field,
        anchor: VoiceEditAnchor(text: text, range: range)
      )
    }
  }

  private func makeHarness(field: FakeVoiceEditField?) -> Harness {
    Harness(field: field)
  }
}

/// The pure anchor checks behind the replacement paths.
final class VoiceEditAnchorStateTests: XCTestCase {
  private typealias Support = VoiceEditTestSupport

  func testEvaluate_prefersTheValueAtTheRecordedRange() {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 19, length: 0))
    let anchor = VoiceEditAnchor(text: "quick", range: Support.range(4, 5))

    XCTAssertEqual(VoiceEditAnchorState.evaluate(anchor, in: field), .intact(Support.range(4, 5)))
    field.value = "The slow brown fox"
    XCTAssertEqual(VoiceEditAnchorState.evaluate(anchor, in: field), .moved)
  }

  func testEvaluate_fallsBackToTheSelectionWhenTheValueIsUnreadable() {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    field.valueReadable = false
    let anchor = VoiceEditAnchor(text: "quick", range: Support.range(4, 5))

    XCTAssertEqual(VoiceEditAnchorState.evaluate(anchor, in: field), .intact(Support.range(4, 5)))
    field.selection = CFRange(location: 0, length: 3)
    XCTAssertEqual(VoiceEditAnchorState.evaluate(anchor, in: field), .moved)
    field.selectionRangeReadable = false
    field.selectedTextReadable = false
    XCTAssertEqual(VoiceEditAnchorState.evaluate(anchor, in: field), .unverifiable)
  }

  func testEvaluateSelection_requiresTheCurrentSelectionToBeTheAnchor() {
    let field = FakeVoiceEditField(value: "The quick brown fox", selection: CFRange(location: 4, length: 5))
    let anchor = VoiceEditAnchor(text: "quick", range: Support.range(4, 5))

    XCTAssertEqual(VoiceEditAnchorState.evaluateSelection(anchor, in: field), .intact(Support.range(4, 5)))
    // Same text still there, but the caret moved: a paste would land in the wrong place.
    field.selection = CFRange(location: 19, length: 0)
    XCTAssertEqual(VoiceEditAnchorState.evaluateSelection(anchor, in: field), .moved)
  }
}
