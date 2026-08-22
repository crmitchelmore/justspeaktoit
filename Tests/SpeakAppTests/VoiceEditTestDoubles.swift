import AppKit
import ApplicationServices
import Foundation

@testable import SpeakApp

// MARK: - Fields

/// In-memory text field with identity, modelling the accessibility contract
/// Voice Edit relies on: a value, a selection, selected text derived from
/// both, and writes that replace the selection and leave a caret after the
/// inserted text.
final class FakeVoiceEditField: VoiceEditField {
  private let id = UUID()
  var value: String
  var selection: CFRange?
  var valueReadable = true
  var selectionRangeReadable = true
  var selectedTextReadable = true
  /// Reported instead of the selection's substring, to model an app whose
  /// selected-text and selected-range attributes disagree.
  var selectedTextOverride: String?
  var setSelectedRangeResult: AXError = .success
  var setSelectedTextResult: AXError = .success
  /// Applied to every accepted write, to model an app that reformats what it receives.
  var transformOnWrite: ((String) -> String)?
  var processIdentifier: pid_t? = ProcessInfo.processInfo.processIdentifier
  private(set) var selectedTextWrites: [(range: CFRange?, text: String)] = []

  init(value: String = "", selection: CFRange? = CFRange(location: 0, length: 0)) {
    self.value = value
    self.selection = selection
  }

  func readValue() -> String? {
    valueReadable ? value : nil
  }

  func readSelectedRange() -> CFRange? {
    selectionRangeReadable ? selection : nil
  }

  func readSelectedText() -> String? {
    guard selectedTextReadable else { return nil }
    if let selectedTextOverride { return selectedTextOverride }
    guard let selection else { return nil }
    return VoiceEditTextRange(selection).substring(of: value)
  }

  func setSelectedRange(_ range: CFRange) -> AXError {
    guard setSelectedRangeResult == .success else { return setSelectedRangeResult }
    selection = range
    return .success
  }

  func setSelectedText(_ text: String) -> AXError {
    selectedTextWrites.append((selection, text))
    guard setSelectedTextResult == .success else { return setSelectedTextResult }
    return apply(text)
  }

  /// What the app does with a ⌘V: replaces the current selection with the pasted text.
  @discardableResult
  func simulatePaste(_ text: String) -> AXError {
    apply(text)
  }

  func isSameField(as other: any VoiceEditField) -> Bool {
    (other as? FakeVoiceEditField)?.id == id
  }

  private func apply(_ text: String) -> AXError {
    guard let selection else { return .failure }
    let range = VoiceEditTextRange(selection)
    guard range.substring(of: value) != nil else { return .failure }
    let written = transformOnWrite?(text) ?? text
    let utf16 = Array(value.utf16)
    let prefix = String(utf16CodeUnits: Array(utf16[0..<range.location]), count: range.location)
    let suffix = String(utf16CodeUnits: Array(utf16[range.end...]), count: utf16.count - range.end)
    value = prefix + written + suffix
    self.selection = CFRange(location: range.location + written.utf16.count, length: 0)
    return .success
  }
}

@MainActor
final class FakeVoiceEditFieldResolver: VoiceEditFieldResolving {
  var captured: FakeVoiceEditField?
  var focused: FakeVoiceEditField?

  init(captured: FakeVoiceEditField? = nil, focused: FakeVoiceEditField? = nil) {
    self.captured = captured
    self.focused = focused ?? captured
  }

  func field(for target: TextOutputTarget) -> (any VoiceEditField)? {
    captured
  }

  func focusedField() -> (any VoiceEditField)? {
    focused
  }
}

// MARK: - Targets and pasteboards

enum VoiceEditTestSupport {
  /// A target describing this test process, which `isApplicationRunning` accepts.
  /// `NSRunningApplication` only knows processes registered with Launch
  /// Services, so AppKit is initialised first; otherwise the answer depends on
  /// which other suites happened to run earlier.
  @MainActor
  static func runningTarget() -> TextOutputTarget {
    _ = NSApplication.shared
    return TextOutputTarget(
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      applicationName: "Tests",
      bundleIdentifier: nil,
      applicationLaunchDate: nil,
      focusedElement: nil
    )
  }

  /// A target whose process no longer exists.
  static func goneTarget() -> TextOutputTarget {
    TextOutputTarget(
      processIdentifier: pid_t.max,
      applicationName: "Gone",
      bundleIdentifier: nil,
      applicationLaunchDate: nil,
      focusedElement: nil
    )
  }

  static func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.speakapp.voice-edit-tests.\(UUID().uuidString)"))
  }

  static func range(_ location: Int, _ length: Int) -> VoiceEditTextRange {
    VoiceEditTextRange(location: location, length: length)
  }
}
