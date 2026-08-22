import ApplicationServices
import Foundation

/// The accessibility surface Voice Edit needs from a text field: everything
/// the ranged streaming path uses, plus the selected text itself and an
/// identity so apply-time focus can be compared with capture-time focus.
///
/// Kept behind a protocol so capture, anchor verification and replacement are
/// testable against an in-memory field, without a live `AXUIElement`.
protocol VoiceEditField: StreamingTextField {
  /// The selected text as the app reports it, or nil when unreadable.
  func readSelectedText() -> String?
  /// The process that owns the field, or nil when unknown.
  var processIdentifier: pid_t? { get }
  /// Whether `other` is the very same control, not merely an equal snapshot.
  func isSameField(as other: any VoiceEditField) -> Bool
}

/// Resolves the field captured with a target and whichever field has focus now.
@MainActor
protocol VoiceEditFieldResolving {
  func field(for target: TextOutputTarget) -> (any VoiceEditField)?
  func focusedField() -> (any VoiceEditField)?
}

/// The live implementation, backed by an accessibility element.
struct AccessibilityVoiceEditField: VoiceEditField {
  let element: AXUIElement
  private let streaming: AccessibilityStreamingTextField

  init(element: AXUIElement) {
    self.element = element
    self.streaming = AccessibilityStreamingTextField(element: element)
  }

  func readValue() -> String? {
    streaming.readValue()
  }

  func readSelectedRange() -> CFRange? {
    streaming.readSelectedRange()
  }

  func setSelectedRange(_ range: CFRange) -> AXError {
    streaming.setSelectedRange(range)
  }

  func setSelectedText(_ text: String) -> AXError {
    streaming.setSelectedText(text)
  }

  func readSelectedText() -> String? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
    guard status == .success else { return nil }
    return value as? String
  }

  var processIdentifier: pid_t? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return nil }
    return pid
  }

  func isSameField(as other: any VoiceEditField) -> Bool {
    guard let other = other as? AccessibilityVoiceEditField else { return false }
    return CFEqual(element, other.element)
  }
}

@MainActor
struct AccessibilityVoiceEditFieldResolver: VoiceEditFieldResolving {
  /// Nonisolated so the resolver can be a default argument of main-actor
  /// initialisers, which evaluate their defaults outside the actor; the
  /// synthesised initialiser would be actor-isolated.
  nonisolated init() {}
  // swiftlint:disable:previous unneeded_synthesized_initializer

  func field(for target: TextOutputTarget) -> (any VoiceEditField)? {
    guard let element = target.focusedElement ?? Self.systemFocusedElement() else { return nil }
    return AccessibilityVoiceEditField(element: element)
  }

  func focusedField() -> (any VoiceEditField)? {
    guard let element = Self.systemFocusedElement() else { return nil }
    return AccessibilityVoiceEditField(element: element)
  }

  private static func systemFocusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var rawFocused: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &rawFocused
    )
    guard status == .success, let rawFocused else { return nil }
    return unsafeBitCast(rawFocused, to: AXUIElement.self)
  }
}
