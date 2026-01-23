import AppKit
import ApplicationServices
import Foundation

/// Handles live incremental text insertion during streaming transcription.
/// Tracks what's been inserted and handles updates/replacements.
/// Falls back to clipboard mode if accessibility insertion isn't available.
@MainActor
final class LiveTextInserter: ObservableObject {
  /// The text that has been successfully inserted
  @Published private(set) var insertedText: String = ""

  /// Whether live insertion is active
  @Published private(set) var isActive: Bool = false

  /// Whether we're using clipboard fallback mode (accessibility not available)
  @Published private(set) var usingClipboardFallback: Bool = false

  /// The last error encountered
  @Published private(set) var lastError: Error?

  private let permissionsManager: PermissionsManager
  private let appSettings: AppSettings

  /// Track the focused element to detect if user changed focus
  private var initialFocusedApp: String?

  /// Character count we've successfully inserted (for incremental updates)
  private var confirmedCharCount: Int = 0

  /// Whether first insertion was verified successfully
  private var firstInsertionVerified: Bool = false

  init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
  }

  /// Start a live insertion session
  func begin() {
    guard canUseAccessibility() else {
      lastError = TextOutputError.accessibilityPermissionMissing
      print("[LiveTextInserter] Cannot start: accessibility permission missing")
      return
    }

    // Check if there's actually a focused text element we can insert into
    guard let focusedElement = getFocusedTextElement() else {
      lastError = TextOutputError.unableToFindFocusedElement
      print("[LiveTextInserter] Cannot start: no focused text element found")
      return
    }

    // Log detailed info about the focused element for debugging
    logFocusedElementInfo(focusedElement)

    // Check if the value attribute is settable
    var settable: DarwinBoolean = false
    let isSettable = AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &settable)
    let canSetValue = isSettable == .success && settable.boolValue

    // If not settable, use clipboard fallback mode
    if !canSetValue {
      print("[LiveTextInserter] Value not settable, will use clipboard fallback")
      usingClipboardFallback = true
    } else {
      usingClipboardFallback = false
    }

    insertedText = ""
    confirmedCharCount = 0
    firstInsertionVerified = false
    isActive = true
    lastError = nil
    initialFocusedApp = NSWorkspace.shared.frontmostApplication?.localizedName
    print(
      "[LiveTextInserter] Started live insertion session, target app: \(initialFocusedApp ?? "unknown"), clipboard fallback: \(usingClipboardFallback)"
    )
  }

  /// End the live insertion session
  func end() {
    if isActive {
      print("[LiveTextInserter] Ended session, inserted \(insertedText.count) characters")
    }
    isActive = false
  }

  /// Reset state for a new session
  func reset() {
    insertedText = ""
    confirmedCharCount = 0
    firstInsertionVerified = false
    usingClipboardFallback = false
    isActive = false
    lastError = nil
    initialFocusedApp = nil
  }

  /// Update with new transcription text - handles incremental insertion
  /// - Parameter newText: The full current transcript (not just the delta)
  func update(with newText: String) {
    guard isActive else { return }
    guard !newText.isEmpty else { return }

    // Check if user switched apps - if so, pause but don't deactivate
    let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName
    if let initial = initialFocusedApp, currentApp != initial {
      // User switched apps, skip this update
      return
    }

    // Calculate what's new since last confirmed insertion
    let trimmedNew = newText.trimmingCharacters(in: .whitespaces)

    // If the new text is shorter (correction), we need to handle replacement
    if trimmedNew.count < insertedText.count {
      // Text got shorter - likely a correction. Replace entire text.
      replaceInsertedText(with: trimmedNew)
    } else if trimmedNew.hasPrefix(insertedText) {
      // New text extends what we have - append the delta
      let delta = String(trimmedNew.dropFirst(insertedText.count))
      if !delta.isEmpty {
        appendText(delta)
      }
    } else {
      // Text changed substantially - replace
      replaceInsertedText(with: trimmedNew)
    }
  }

  /// Apply final polished text - replaces what was inserted with polished version
  func applyPolishedFinal(_ polishedText: String) {
    guard !insertedText.isEmpty else {
      // Nothing was inserted live, just do normal insertion
      insertFresh(polishedText)
      return
    }

    // Replace the live-inserted text with the polished version
    replaceInsertedText(with: polishedText)
  }

  // MARK: - Private Methods

  private func canUseAccessibility() -> Bool {
    let status = permissionsManager.status(for: .accessibility)
    return status.isGranted
  }

  private func appendText(_ text: String) {
    guard let focusedElement = getFocusedTextElement() else {
      lastError = TextOutputError.unableToFindFocusedElement
      print("[LiveTextInserter] appendText failed: no focused element")
      return
    }

    // Get current value
    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      focusedElement, kAXValueAttribute as CFString, &currentValue
    )

    var newValue: String
    if getStatus == .success, let current = currentValue as? String {
      newValue = current + text
    } else {
      // No existing value, just set the new text
      newValue = insertedText + text
    }

    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, newValue as CFTypeRef
    )

    if setResult == .success {
      // Verify first insertion to ensure accessibility is actually working
      if !firstInsertionVerified {
        if verifyInsertion(expected: newValue, element: focusedElement) {
          firstInsertionVerified = true
          print("[LiveTextInserter] First insertion verified successfully")
        } else {
          print("[LiveTextInserter] First insertion verification failed, switching to clipboard fallback")
          usingClipboardFallback = true
          return
        }
      }

      insertedText += text
      confirmedCharCount = insertedText.count
      print("[LiveTextInserter] Appended \(text.count) chars, total: \(insertedText.count)")
    } else {
      lastError = TextOutputError.unableToSetValue(setResult)
      print("[LiveTextInserter] appendText failed with AXError: \(setResult.rawValue)")
    }
  }

  private func replaceInsertedText(with newText: String) {
    guard let focusedElement = getFocusedTextElement() else {
      lastError = TextOutputError.unableToFindFocusedElement
      return
    }

    // Get current field value
    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      focusedElement, kAXValueAttribute as CFString, &currentValue
    )

    var finalValue: String
    if getStatus == .success, let current = currentValue as? String {
      // Remove what we previously inserted, add the new text
      if current.hasSuffix(insertedText) && !insertedText.isEmpty {
        let prefix = String(current.dropLast(insertedText.count))
        finalValue = prefix + newText
      } else {
        // Can't find our inserted text - just append
        finalValue = current.isEmpty ? newText : current
      }
    } else {
      finalValue = newText
    }

    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, finalValue as CFTypeRef
    )

    if setResult == .success {
      insertedText = newText
      confirmedCharCount = insertedText.count
    } else {
      lastError = TextOutputError.unableToSetValue(setResult)
    }
  }

  private func insertFresh(_ text: String) {
    guard let focusedElement = getFocusedTextElement() else {
      lastError = TextOutputError.unableToFindFocusedElement
      return
    }

    // Get current value and append
    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      focusedElement, kAXValueAttribute as CFString, &currentValue
    )

    var newValue: String
    if getStatus == .success, let current = currentValue as? String {
      newValue = current + text
    } else {
      newValue = text
    }

    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, newValue as CFTypeRef
    )

    if setResult == .success {
      insertedText = text
      confirmedCharCount = text.count
    } else {
      lastError = TextOutputError.unableToSetValue(setResult)
    }
  }

  private func getFocusedTextElement() -> AXUIElement? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var rawFocused: CFTypeRef?
    let copyStatus = AXUIElementCopyAttributeValue(
      systemWideElement, kAXFocusedUIElementAttribute as CFString, &rawFocused
    )

    guard copyStatus == .success, let rawFocused else {
      return nil
    }

    return unsafeBitCast(rawFocused, to: AXUIElement.self)
  }

  /// Log detailed information about the focused element for debugging
  private func logFocusedElementInfo(_ element: AXUIElement) {
    var role: CFTypeRef?
    var roleDesc: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDesc)
    let roleStr = (role as? String) ?? "unknown"
    let roleDescStr = (roleDesc as? String) ?? "unknown"
    print("[LiveTextInserter] Focused element - role: \(roleStr), description: \(roleDescStr)")
  }

  /// Verify that text was actually inserted by re-reading the value after a short delay
  private func verifyInsertion(expected: String, element: AXUIElement) -> Bool {
    // Wait 50ms for the target app to process the accessibility change
    Thread.sleep(forTimeInterval: 0.05)

    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      element, kAXValueAttribute as CFString, &currentValue
    )
    guard getStatus == .success, let currentString = currentValue as? String else {
      return false
    }
    return currentString == expected || currentString.hasSuffix(expected)
  }
}
