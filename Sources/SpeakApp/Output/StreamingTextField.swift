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
  /// The document the field currently shows (the `AXDocument` URL of the
  /// field or its window), or `nil` when the app does not report one. Apps
  /// such as Notes reuse one element for every note (#664), so equal text is
  /// no proof the field still shows the same document; this is.
  func readDocumentIdentity() -> String?
}

extension StreamingTextField {
  func readDocumentIdentity() -> String? { nil }
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

  func readDocumentIdentity() -> String? {
    if let document = Self.copyString(self.element, kAXDocumentAttribute), !document.isEmpty {
      return document
    }
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(self.element, kAXWindowAttribute as CFString, &window) == .success,
          let window, CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    let document = Self.copyString(unsafeBitCast(window, to: AXUIElement.self), kAXDocumentAttribute)
    return document?.isEmpty == false ? document : nil
  }

  private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }
}
