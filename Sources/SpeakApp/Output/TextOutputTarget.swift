import AppKit
import ApplicationServices
import Foundation
import SpeakCore
import os.log

/// The app and text control that owned keyboard focus when a transcription session began.
/// Keeping this target avoids delivering into an unrelated app if focus changes while the
/// recording is transcribed or post-processed.
struct TextOutputTarget {
  let processIdentifier: pid_t?
  let applicationName: String?
  let bundleIdentifier: String?
  let applicationLaunchDate: Date?
  let focusedElement: AXUIElement?
  /// Set when this target was chosen because it was the frontmost app at
  /// delivery time (the "app you're in now" option). Every sink rechecks
  /// that it is still frontmost immediately before writing, so a second app
  /// switch cannot redirect the transcript into an app the user has left.
  var requiresFrontmostAtDelivery = false

  static func capture() -> TextOutputTarget {
    let application = NSWorkspace.shared.frontmostApplication
    guard DistributionChannel.current.supportsAccessibilityTextInsertion else {
      return TextOutputTarget(
        processIdentifier: application?.processIdentifier,
        applicationName: application?.localizedName,
        bundleIdentifier: application?.bundleIdentifier,
        applicationLaunchDate: application?.launchDate,
        focusedElement: nil
      )
    }
    return TextOutputTarget(
      processIdentifier: application?.processIdentifier,
      applicationName: application?.localizedName,
      bundleIdentifier: application?.bundleIdentifier,
      applicationLaunchDate: application?.launchDate,
      focusedElement: currentSystemFocusedElement()
    )
  }

  var isApplicationRunning: Bool {
    guard
      let processIdentifier,
      let application = NSRunningApplication(processIdentifier: processIdentifier),
      !application.isTerminated
    else {
      return false
    }
    if let bundleIdentifier, application.bundleIdentifier != bundleIdentifier {
      return false
    }
    if let applicationLaunchDate, application.launchDate != applicationLaunchDate {
      return false
    }
    return true
  }

  /// Whether the captured AX element belongs to the captured process. An
  /// AXUIElement is bound to one process for its lifetime, so a mismatch means
  /// the capture raced an app switch and the element must not be used
  /// (issue #707).
  func capturedElementBelongsToCapturedProcess() -> Bool {
    guard let focusedElement, let processIdentifier else { return false }
    var elementProcessIdentifier: pid_t = 0
    guard AXUIElementGetPid(focusedElement, &elementProcessIdentifier) == .success else {
      return false
    }
    return elementProcessIdentifier == processIdentifier
  }

  /// Field-identity confirmation for keystroke-based delivery (issue #707).
  enum CapturedFieldConfirmation: Equatable {
    /// The captured field is the captured process's current focus.
    case confirmed
    /// No AX element was captured, so field identity cannot be proven.
    case fieldUnavailable
    /// The captured process is not frontmost, or focus moved to a different
    /// field (for example another conversation in the same app).
    case fieldChanged
  }

  /// Confirms that a simulated paste would land in the captured field: the
  /// captured process must be frontmost and its current focused element must
  /// be the captured element. PID-directed events reach a process, not a
  /// field, so without this proof a paste can land in whichever field owns
  /// focus now (issue #707).
  func confirmCapturedFieldOwnsFocus(
    frontmostProcessIdentifier: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier,
    currentFocus: () -> AXUIElement? = currentSystemFocusedElement
  ) -> CapturedFieldConfirmation {
    guard let focusedElement else { return .fieldUnavailable }
    guard capturedElementBelongsToCapturedProcess(),
          let frontmostProcessIdentifier,
          frontmostProcessIdentifier == processIdentifier,
          let current = currentFocus(),
          CFEqual(current, focusedElement)
    else {
      return .fieldChanged
    }
    return .confirmed
  }

  /// Clipboard delivery must still work for users who deliberately have not
  /// granted Accessibility access. In that mode macOS will not expose a field
  /// identity, so the strongest safe check available is that the captured app
  /// is still the frontmost app. This preserves the pre-2.61 clipboard path
  /// without allowing a paste into a different application.
  func capturedApplicationIsFrontmost(
    frontmostProcessIdentifier: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
  ) -> Bool {
    guard isApplicationRunning, let processIdentifier, let frontmostProcessIdentifier else {
      return false
    }
    return processIdentifier == frontmostProcessIdentifier
  }

  /// Fails closed when a redirected destination is no longer frontmost.
  func destinationChangedError(
    frontmostProcessIdentifier: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
  ) -> TextOutputError? {
    guard requiresFrontmostAtDelivery else { return nil }
    return Self.destinationChangedError(
      requiresFrontmost: true,
      isFrontmost: capturedApplicationIsFrontmost(frontmostProcessIdentifier: frontmostProcessIdentifier)
    )
  }

  static func destinationChangedError(requiresFrontmost: Bool, isFrontmost: Bool) -> TextOutputError? {
    requiresFrontmost && !isFrontmost ? .destinationApplicationChanged : nil
  }
}
