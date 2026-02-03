/* @Context # Smart Text Insertion Implementation Blueprint

This guide explains how to integrate an "Insert" action that prefers Accessibility value injection and automatically falls back to a Command+V paste. Follow the steps in order; each section points to the relevant code inside this project so a junior engineer can reproduce the behaviour in another app.

## 1. Extend the Text Injector Facade

### 1.1 Define a Result Payload
- File: `Sources/PasteDelayApp/TextInjector.swift:12`
- Add `TextInjector.Result` with two stored properties:
  - `method: Method` tracks which delivery path succeeded.
  - `fallbackReason: InjectionError?` captures (optional) context when the pasteboard fallback runs.
- Implement a `successMessage` computed property that renders user-facing status text depending on the path used. Keep pasteboard-fallback messaging explicit: `Sent text using Command+V fallback (<reason>).`

### 1.2 Enrich InjectionError
- File: `Sources/PasteDelayApp/TextInjector.swift:29`
- Ensure `InjectionError` covers `emptyPayload`, `accessibilityDenied`, `noFocusedElement`, and `valueNotSettable`.
// @Implement: This implementation should use the clipboard to paste text into the focused app. It should restore the previous pasteboard value (if the app setting output to clipboard is false) It should respect any relevant settings from app settings
import AppKit
import ApplicationServices
import Foundation
- Restore the clipboard after pasteboard-based injection to avoid surprising users.
- Document fallback behaviour prominently in user-facing copy so expectations stay aligned.

Following this sequence allows another project to drop in the same smart Insert capability with minimal guesswork.
 */

import AppKit
import ApplicationServices
import Foundation

struct TextOutputResult {
  let method: HistoryTrigger.OutputMethod
  let error: Error?
}

@MainActor
protocol TextOutputting {
  func output(text: String) -> TextOutputResult
}

enum TextOutputError: LocalizedError {
  case accessibilityPermissionMissing
  case unableToFindFocusedElement
  case unableToSetValue(AXError)
  case clipboardWriteFailed

  var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      return "Accessibility permission is required to insert text directly."
    case .unableToFindFocusedElement:
      return "No focused field was detected."
    case .unableToSetValue(let status):
      return "Unable to set text via accessibility APIs (status: \(status.rawValue))."
    case .clipboardWriteFailed:
      return "Failed to write to the clipboard."
    }
  }
}

// @Implement: This implementation should check for accessibility permissions and use the accessibility API to paste text into the focused app. It should respect any relevant settings from app settings
@MainActor
struct AccessibilityTextOutput: TextOutputting {
  let permissionsManager: PermissionsManager
  let appSettings: AppSettings

  func output(text: String) -> TextOutputResult {
    let status = permissionsManager.status(for: .accessibility)
    guard status.isGranted else {
      return TextOutputResult(
        method: .none,
        error: TextOutputError.accessibilityPermissionMissing
      )
    }

    let systemWideElement = AXUIElementCreateSystemWide()
    var rawFocused: CFTypeRef?
    let copyStatus = AXUIElementCopyAttributeValue(
      systemWideElement, kAXFocusedUIElementAttribute as CFString, &rawFocused)
    guard copyStatus == .success, let rawFocused else {
      return TextOutputResult(
        method: .none,
        error: TextOutputError.unableToFindFocusedElement
      )
    }

    let focusedElement = unsafeBitCast(rawFocused, to: AXUIElement.self)

    let setResult = AXUIElementSetAttributeValue(
      focusedElement, kAXValueAttribute as CFString, text as CFTypeRef)
    guard setResult == .success else {
      return TextOutputResult(
        method: .none,
        error: TextOutputError.unableToSetValue(setResult)
      )
    }

    return TextOutputResult(method: .accessibility, error: nil)
  }
}

// @Implement: This implementation should use the clipboard to paste text into the focused app. It should restore the previous pasteboard value (if the app setting output to clipboard is false) It should respect any relevant settings from app settings
@MainActor
struct PasteTextOutput: TextOutputting {
  let permissionsManager: PermissionsManager
  let appSettings: AppSettings

  func output(text: String) -> TextOutputResult {
    let pasteboard = NSPasteboard.general
    let restoreClipboard = appSettings.restoreClipboardAfterPaste
    let previousString = restoreClipboard ? pasteboard.string(forType: .string) : nil

    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      return TextOutputResult(method: .none, error: TextOutputError.clipboardWriteFailed)
    }

    simulatePasteShortcut()

    if restoreClipboard {
      scheduleClipboardRestore(previousString, on: pasteboard)
    }

    return TextOutputResult(method: .clipboard, error: nil)
  }

  private func simulatePasteShortcut() {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
    let vKey: CGKeyCode = 9

    if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true) {
      keyDown.flags = .maskCommand
      keyDown.post(tap: .cghidEventTap)
    }

    if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
      keyUp.flags = .maskCommand
      keyUp.post(tap: .cghidEventTap)
    }
  }

  private func scheduleClipboardRestore(_ previousString: String?, on pasteboard: NSPasteboard) {
    let delay = DispatchTime.now() + .milliseconds(300)
    DispatchQueue.main.asyncAfter(deadline: delay) {
      pasteboard.clearContents()
      if let previousString {
        pasteboard.setString(previousString, forType: .string)
      }
    }
  }
}

// @Implement: Smart text output that uses accessibility when permitted and falls back to clipboard.
@MainActor
struct SmartTextOutput: TextOutputting {
  let permissionsManager: PermissionsManager
  let appSettings: AppSettings

  /// Apps known to not support accessibility text insertion properly.
  /// These apps will always use clipboard fallback when in "smart" mode.
  private static let problematicApps: Set<String> = [
    // Chromium-based browsers
    "Google Chrome",
    "Google Chrome Canary",
    "Chromium",
    "Microsoft Edge",
    "Brave Browser",
    "Opera",
    "Vivaldi",
    "Arc",
    // Electron apps
    "Slack",
    "Discord",
    "Visual Studio Code",
    "VS Code",
    "Code",
    "Cursor",
    "Atom",
    "Notion",
    "Figma",
    "Obsidian",
    "Postman",
    "Insomnia",
    "GitHub Desktop",
    "Hyper",
    "Terminus",
    "1Password",
    "Bitwarden",
    "Spotify",
    "Teams",
    "Microsoft Teams",
    "Zoom",
    "Webex",
    // Other apps with known issues
    "Microsoft Word",
    "Microsoft Excel",
    "Microsoft PowerPoint",
    "Firefox",
    "iTerm2",
    "iTerm",
    "Alacritty",
    "kitty",
    "Warp",
    "Terminal", // Some secure input issues
  ]

  private var accessibilityOutput: AccessibilityTextOutput {
    AccessibilityTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
  }

  private var clipboardOutput: PasteTextOutput {
    PasteTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
  }

  func output(text: String) -> TextOutputResult {
    switch appSettings.textOutputMethod {
    case .accessibilityOnly:
      return accessibilityOutput.output(text: text)
    case .clipboardOnly:
      return clipboardOutput.output(text: text)
    case .smart:
      // Skip accessibility for known problematic apps
      if isCurrentAppProblematic() {
        print("[SmartTextOutput] Skipping accessibility for problematic app, using clipboard")
        return clipboardOutput.output(text: text)
      }

      // Only try accessibility if permission is granted AND there's a focused element
      if permissionsManager.status(for: .accessibility).isGranted,
         let focusedElement = getFocusedElement() {

        // Log element info for debugging
        logFocusedElementInfo(focusedElement)

        // Check if the attribute is settable
        var settable: DarwinBoolean = false
        let isSettable = AXUIElementIsAttributeSettable(
          focusedElement, kAXValueAttribute as CFString, &settable)
        guard isSettable == .success && settable.boolValue else {
          print("[SmartTextOutput] Value attribute not settable, falling back to clipboard")
          return clipboardOutput.output(text: text)
        }

        // Try accessibility insertion
        let result = accessibilityOutput.output(text: text)
        if result.error == nil {
          // Verify the text was actually inserted by re-reading the value
          if verifyTextInserted(text: text, element: focusedElement) {
            return result
          } else {
            print("[SmartTextOutput] Text insertion not verified, falling back to clipboard")
          }
        }
      }
      return clipboardOutput.output(text: text)
    }
  }

  private func isCurrentAppProblematic() -> Bool {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
      return false
    }
    let appName = frontmostApp.localizedName ?? ""
    return Self.problematicApps.contains(appName)
  }

  private func getFocusedElement() -> AXUIElement? {
    let systemWideElement = AXUIElementCreateSystemWide()
    var rawFocused: CFTypeRef?
    let copyStatus = AXUIElementCopyAttributeValue(
      systemWideElement, kAXFocusedUIElementAttribute as CFString, &rawFocused)
    guard copyStatus == .success, let rawFocused else {
      return nil
    }
    return unsafeBitCast(rawFocused, to: AXUIElement.self)
  }

  /// Verify that the text was actually inserted into the focused element.
  /// Some apps return success from AXUIElementSetAttributeValue but don't actually update.
  /// Includes a 50ms delay to allow the target app to process the change.
  private func verifyTextInserted(text: String, element: AXUIElement) -> Bool {
    // Wait 50ms for the target app to process the accessibility change
    // Using async Task.sleep to prevent UI blocking
    let semaphore = DispatchSemaphore(value: 0)
    var result = false
    
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(50))
      
      var currentValue: CFTypeRef?
      let getStatus = AXUIElementCopyAttributeValue(
        element, kAXValueAttribute as CFString, &currentValue)
      if getStatus == .success, let currentString = currentValue as? String {
        // Check if the text appears at the end (it should have been appended or set)
        result = currentString.hasSuffix(text) || currentString == text
      }
      semaphore.signal()
    }
    
    semaphore.wait()
    return result
  }

  /// Log information about the focused element for debugging
  private func logFocusedElementInfo(_ element: AXUIElement) {
    var role: CFTypeRef?
    var roleDesc: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDesc)
    let roleStr = (role as? String) ?? "unknown"
    let roleDescStr = (roleDesc as? String) ?? "unknown"
    print("[SmartTextOutput] Focused element - role: \(roleStr), description: \(roleDescStr)")
  }
}
