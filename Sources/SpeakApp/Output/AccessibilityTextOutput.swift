import AppKit
import ApplicationServices
import Foundation
import SpeakCore
import os.log

/// Inserts through the Accessibility API into the captured (or focused) field.
@MainActor
struct AccessibilityTextOutput: TextOutputting {
  let permissionsManager: PermissionsManager
  let appSettings: AppSettings

  func output(text: String, target: TextOutputTarget?) -> TextOutputResult {
    permissionsManager.refresh(.accessibility)
    let status = permissionsManager.status(for: .accessibility)
    guard status.isGranted else {
      return TextOutputResult(
        method: .none,
        error: TextOutputError.accessibilityPermissionMissing
      )
    }

    if let target, !target.isApplicationRunning {
      return TextOutputResult(
        method: .none,
        error: TextOutputError.targetApplicationUnavailable
      )
    }

    let focusedElement: AXUIElement
    switch Self.resolveDeliveryElement(for: target) {
    case .success(let element):
      focusedElement = element
    case .failure(let error):
      return TextOutputResult(method: .none, error: error)
    }

    if let changed = target?.destinationChangedError() {
      return TextOutputResult(method: .none, error: changed)
    }

    switch appSettings.accessibilityInsertionMode {
    case .insertAtCursor:
      return AccessibilityInsertionWriter.insertAtCursor(
        text: text,
        selectedRange: { AccessibilityStreamingTextField(element: focusedElement).readSelectedRange() },
        destinationError: { target?.destinationChangedError() },
        setSelectedText: {
          AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        },
        setValue: { AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, text as CFTypeRef) }
      )

    case .replaceAll:
      return AccessibilityInsertionWriter.replaceAll(
        text: text, destinationError: { target?.destinationChangedError() },
        setValue: { AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, text as CFTypeRef) }
      )
    }
  }

  /// A non-nil target is a captured-field contract: when its AX element is
  /// missing (capture failed) or belongs to another process (the capture
  /// raced an app switch), never resolve the *current* focus in its place —
  /// that is how a transcript lands in an unrelated app (issue #707).
  /// `target == nil` remains the explicit current-focus operation.
  static func resolveDeliveryElement(
    for target: TextOutputTarget?
  ) -> Result<AXUIElement, TextOutputError> {
    if let target {
      guard let captured = target.focusedElement else {
        return .failure(.capturedFieldUnavailable)
      }
      guard target.capturedElementBelongsToCapturedProcess() else {
        return .failure(.capturedFieldChanged)
      }
      return .success(captured)
    }
    guard let current = currentSystemFocusedElement() else {
      return .failure(.unableToFindFocusedElement)
    }
    return .success(current)
  }
}
