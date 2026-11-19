import AppKit
import ApplicationServices
import Foundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "TextOutput")

/// Picks the delivery route: Accessibility when permitted and the app supports
/// it, the clipboard paste otherwise, and the app-switch policy when focus moved.
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
    "Terminal" // Some secure input issues
  ]

  private var accessibilityOutput: AccessibilityTextOutput {
    AccessibilityTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
  }

  private var clipboardOutput: PasteTextOutput {
    PasteTextOutput(permissionsManager: permissionsManager, appSettings: appSettings)
  }

  func output(text: String, target: TextOutputTarget?) -> TextOutputResult {
    guard DistributionChannel.current.supportsAccessibilityTextInsertion else {
      return clipboardOutput.output(text: text, target: target)
    }

    guard let target else {
      return deliver(text: text, target: nil)
    }
    if target.requiresFrontmostAtDelivery {
      // The destination was already chosen by live finalization. Never follow
      // another app switch back into a field holding this session's partials.
      if let error = target.destinationChangedError() {
        return Self.keepOnClipboard(text: text, error: error)
      }
      var result = deliver(text: text, target: target)
      result.redirectedTarget = target
      return result
    }
    let decision = Self.currentAppSwitchDecision(policy: appSettings.appSwitchDelivery, target: target)
    switch decision {
    case .deliverToOriginal(let focusMoved):
      var result = deliver(text: text, target: target)
      result.focusMovedToOtherApplication = focusMoved
      return result
    case .deliverToCurrentApp:
      return deliverToCurrentApp(text: text, originalTarget: target)
    case .keepOnClipboard:
      logger.info("Original app is not in front; keeping the transcript on the clipboard")
      return Self.keepOnClipboard(text: text, error: .originalApplicationNotInFront(target.applicationName))
    }
  }

  static func currentAppSwitchDecision(
    policy: AppSettings.AppSwitchDelivery, target: TextOutputTarget
  ) -> AppSwitchDecision {
    let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
    return appSwitchDecision(
      policy: policy,
      capturedApplicationIsFrontmost: target.capturedApplicationIsFrontmost(
        frontmostProcessIdentifier: frontmostProcessIdentifier
      ),
      capturedApplicationIsRunning: target.isApplicationRunning,
      frontmostProcessIdentifier: frontmostProcessIdentifier
    )
  }

  private func deliverToCurrentApp(text: String, originalTarget: TextOutputTarget) -> TextOutputResult {
    var current = TextOutputTarget.capture()
    current.requiresFrontmostAtDelivery = true
    guard Self.isUsableRedirectDestination(processIdentifier: current.processIdentifier) else {
      logger.info("No other app is in front any more; keeping the transcript on the clipboard")
      return Self.keepOnClipboard(text: text, error: .destinationApplicationChanged)
    }
    let originalApp = originalTarget.applicationName ?? "unknown"
    let currentApp = current.applicationName ?? "unknown"
    logger.info(
      "Focus moved from \(originalApp, privacy: .private) to \(currentApp, privacy: .private); delivering there"
    )
    var result = deliver(text: text, target: current)
    if case .destinationApplicationChanged? = result.error as? TextOutputError {
      logger.info("Focus moved again before insertion; keeping the transcript on the clipboard")
      // Accessibility-only delivery never touched the clipboard.
      if result.method != .clipboard {
        result = Self.keepOnClipboard(text: text, error: .destinationApplicationChanged)
      }
      return result
    }
    result.redirectedTarget = current
    return result
  }

  /// A redirect needs a real app other than Speak in front; anything else
  /// means the user moved on and there is no safe destination.
  static func isUsableRedirectDestination(
    processIdentifier: pid_t?,
    ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
  ) -> Bool {
    guard let processIdentifier else { return false }
    return processIdentifier != ownProcessIdentifier
  }

  enum AppSwitchDecision: Equatable {
    /// Deliver to the captured target. `focusMoved` is true when the user is
    /// in another app, so the message can say where the text went.
    case deliverToOriginal(focusMoved: Bool)
    case deliverToCurrentApp
    case keepOnClipboard
  }

  /// Applies the user's "If you switch apps" setting to where the user is now.
  static func appSwitchDecision(
    policy: AppSettings.AppSwitchDelivery,
    capturedApplicationIsFrontmost: Bool,
    capturedApplicationIsRunning: Bool,
    frontmostProcessIdentifier: pid_t?,
    ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
  ) -> AppSwitchDecision {
    switch policy {
    case .onlyIfOriginalAppInFront:
      // Strict: anything other than the original app in front — including
      // Speak's own windows — means "don't insert". A quit app still goes
      // through delivery, which reports it as unavailable.
      guard capturedApplicationIsFrontmost || !capturedApplicationIsRunning else {
        return .keepOnClipboard
      }
      return .deliverToOriginal(focusMoved: false)
    case .originalApp, .currentApp:
      let focusMoved = focusMovedToOtherApplication(
        capturedApplicationIsFrontmost: capturedApplicationIsFrontmost,
        frontmostProcessIdentifier: frontmostProcessIdentifier,
        ownProcessIdentifier: ownProcessIdentifier
      )
      if focusMoved, policy == .currentApp {
        return .deliverToCurrentApp
      }
      return .deliverToOriginal(focusMoved: focusMoved)
    }
  }

  static func keepOnClipboard(text: String, error: TextOutputError) -> TextOutputResult {
    guard PasteTextOutput.hasDeliverableText(text) else {
      return TextOutputResult(method: .none, error: nil)
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      return TextOutputResult(method: .none, error: TextOutputError.clipboardWriteFailed)
    }
    return TextOutputResult(method: .clipboard, error: error)
  }

  /// Whether the user is now in a different app from the one captured when
  /// recording started (or that app has quit). Speak's own windows do not
  /// count: activating the menu bar or the main window is not a choice of a
  /// new destination.
  static func focusMovedToOtherApplication(
    capturedApplicationIsFrontmost: Bool,
    frontmostProcessIdentifier: pid_t?,
    ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
  ) -> Bool {
    guard !capturedApplicationIsFrontmost,
          let frontmostProcessIdentifier,
          frontmostProcessIdentifier != ownProcessIdentifier
    else {
      return false
    }
    return true
  }

  private func deliver(text: String, target: TextOutputTarget?) -> TextOutputResult {
    switch appSettings.textOutputMethod {
    case .accessibilityOnly:
      return accessibilityOutput.output(text: text, target: target)
    case .clipboardOnly:
      return clipboardOutput.output(text: text, target: target)
    case .smart:
      if let target, !target.isApplicationRunning {
        return clipboardOutput.output(text: text, target: target)
      }
      // Skip accessibility for known problematic apps
      if isProblematic(target: target) {
        logger.info("Skipping accessibility for problematic app, using clipboard")
        return clipboardOutput.output(text: text, target: target)
      }

      // Permission grants can change while System Settings is frontmost. Re-read
      // TCC before deciding whether direct insertion is available.
      permissionsManager.refresh(.accessibility)

      // Only try accessibility if permission is granted AND the captured
      // field (or, with no target, current focus) resolved. A missing or
      // cross-process captured element falls through to the clipboard path,
      // whose own field-identity gate decides about the paste keystroke —
      // never to current focus (issue #707).
      if permissionsManager.status(for: .accessibility).isGranted,
         case .success(let focusedElement) = AccessibilityTextOutput.resolveDeliveryElement(for: target) {

        // Log element info for debugging
        logFocusedElementInfo(focusedElement)

        // Check if the attribute is settable
        var settable: DarwinBoolean = false
        let isSettable = AXUIElementIsAttributeSettable(
          focusedElement, kAXValueAttribute as CFString, &settable)
        guard isSettable == .success && settable.boolValue else {
          logger.info("Value attribute not settable, falling back to clipboard")
          return clipboardOutput.output(text: text, target: target)
        }

        // Try accessibility insertion
        let result = accessibilityOutput.output(text: text, target: target)
        if result.error == nil {
          // Verify the text was actually inserted by re-reading the value
          if verifyTextInserted(text: text, element: focusedElement) {
            return result
          } else {
            logger.info("Text insertion not verified, falling back to clipboard")
          }
        }
      }
      return clipboardOutput.output(text: text, target: target)
    }
  }

  private func isProblematic(target: TextOutputTarget?) -> Bool {
    let appName = target?.applicationName
      ?? NSWorkspace.shared.frontmostApplication?.localizedName
      ?? ""
    return Self.problematicApps.contains(appName)
  }

  /// Verify that the text was actually inserted into the focused element.
  /// Some apps return success from AXUIElementSetAttributeValue but don't actually update.
  /// Includes a brief spin to allow the target app to process the change.
  private func verifyTextInserted(text: String, element: AXUIElement) -> Bool {
    // Brief pause for the target app to process the accessibility change.
    // Thread.sleep is acceptable here — this is a tiny delay and avoids
    // the deadlock that DispatchSemaphore + MainActor Task would cause.
    Thread.sleep(forTimeInterval: 0.05)

    var currentValue: CFTypeRef?
    let getStatus = AXUIElementCopyAttributeValue(
      element, kAXValueAttribute as CFString, &currentValue)
    if getStatus == .success, let currentString = currentValue as? String {
      // With insert-at-cursor the text could be anywhere in the field
      return currentString.contains(text) || currentString == text
    }
    return false
  }

  /// Log information about the focused element for debugging
  private func logFocusedElementInfo(_ element: AXUIElement) {
    var role: CFTypeRef?
    var roleDesc: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDesc)
    let roleStr = (role as? String) ?? "unknown"
    let roleDescStr = (roleDesc as? String) ?? "unknown"
    logger.debug(
      "Focused element - role: \(roleStr, privacy: .public), description: \(roleDescStr, privacy: .public)")
  }
}
