import ApplicationServices
import Foundation

/// The complete accessibility surface the ranged streaming insertion path
/// depends on: read the field's text, read the caret/selection, move the
/// selection, and replace whatever it covers.
///
/// Keeping the surface this narrow lets the streaming orchestration — anchoring,
/// region re-validation, pause/defer policy — be exercised against an in-memory
/// field, so the never-duplicate and never-overwrite rules are testable without
/// a live `AXUIElement`.
protocol StreamingTextField {
  /// The field's whole value, or `nil` when the app refuses to report it.
  func readValue() -> String?
  /// The current selection (a zero-length range is a caret), or `nil` when unreadable.
  func readSelectedRange() -> CFRange?
  /// Moves the selection; `.success` when the app accepted it.
  func setSelectedRange(_ range: CFRange) -> AXError
  /// Replaces the current selection; `.success` when the app accepted it.
  func setSelectedText(_ text: String) -> AXError
}

/// The live implementation, backed by the focused accessibility element.
struct AccessibilityStreamingTextField: StreamingTextField {
  private let element: AXUIElement

  init(element: AXUIElement) {
    self.element = element
  }

  func readValue() -> String? {
    var currentValue: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      self.element, kAXValueAttribute as CFString, &currentValue
    )
    guard status == .success, let text = currentValue as? String else { return nil }
    return text
  }

  func readSelectedRange() -> CFRange? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      self.element, kAXSelectedTextRangeAttribute as CFString, &value
    )
    guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
      return nil
    }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }

  func setSelectedRange(_ range: CFRange) -> AXError {
    var range = range
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return .failure }
    return AXUIElementSetAttributeValue(
      self.element, kAXSelectedTextRangeAttribute as CFString, rangeValue
    )
  }

  func setSelectedText(_ text: String) -> AXError {
    AXUIElementSetAttributeValue(
      self.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
    )
  }
}
