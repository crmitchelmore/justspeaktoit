import AppKit
import XCTest

@testable import SpeakApp

final class TextOutputTests: XCTestCase {
  @MainActor
  func testOutput_emptyTranscript_PreservesClipboard() {
    let suiteName = "com.speakapp.text-output-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
    defer {
      pasteboard.clearContents()
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    pasteboard.clearContents()
    pasteboard.setString("existing clipboard", forType: .string)

    let output = PasteTextOutput(
      permissionsManager: PermissionsManager(statusProvider: { _ in .denied }),
      appSettings: AppSettings(defaults: defaults),
      pasteboard: pasteboard
    )

    let result = output.output(text: " \n\t ")

    XCTAssertEqual(result.method, .none)
    XCTAssertNil(result.error)
    XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
  }

  @MainActor
  func testHasDeliverableText_emptyAndWhitespace_ReturnsFalse() {
    XCTAssertFalse(PasteTextOutput.hasDeliverableText(""))
    XCTAssertFalse(PasteTextOutput.hasDeliverableText(" \n\t "))
  }

  @MainActor
  func testHasDeliverableText_transcript_ReturnsTrue() {
    XCTAssertTrue(PasteTextOutput.hasDeliverableText("Foreground recording works."))
  }

  @MainActor
  func testEventDestination_capturedRunningProcess_TargetsThatProcess() {
    let target = TextOutputTarget(
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      applicationName: "Tests",
      bundleIdentifier: nil,
      applicationLaunchDate: nil,
      focusedElement: nil
    )

    XCTAssertEqual(
      PasteTextOutput.eventDestination(for: target),
      .process(ProcessInfo.processInfo.processIdentifier)
    )
  }

  @MainActor
  func testEventDestination_terminatedTarget_DoesNotPasteIntoCurrentApp() {
    let target = TextOutputTarget(
      processIdentifier: pid_t.max,
      applicationName: "Terminated",
      bundleIdentifier: nil,
      applicationLaunchDate: nil,
      focusedElement: nil
    )

    XCTAssertEqual(PasteTextOutput.eventDestination(for: target), .none)
  }

  @MainActor
  func testEventDestination_withoutCapturedTarget_UsesSystemEventStream() {
    XCTAssertEqual(PasteTextOutput.eventDestination(for: nil), .system)
  }

  @MainActor
  func testEventDestination_reusedProcessIdentifier_DoesNotTargetDifferentApplication() {
    let target = TextOutputTarget(
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      applicationName: "Tests",
      bundleIdentifier: "invalid.reused-process",
      applicationLaunchDate: nil,
      focusedElement: nil
    )

    XCTAssertEqual(PasteTextOutput.eventDestination(for: target), .none)
  }

  #if !APP_STORE
  @MainActor
  func testOutput_terminatedTarget_KeepsTranscriptOnClipboard() {
    let suiteName = "com.speakapp.text-output-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
    defer {
      pasteboard.clearContents()
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    let settings = AppSettings(defaults: defaults)
    settings.restoreClipboardAfterPaste = true
    let output = PasteTextOutput(
      permissionsManager: PermissionsManager(statusProvider: { _ in .denied }),
      appSettings: settings,
      pasteboard: pasteboard
    )
    let target = TextOutputTarget(
      processIdentifier: pid_t.max,
      applicationName: "Terminated",
      bundleIdentifier: nil,
      applicationLaunchDate: nil,
      focusedElement: nil
    )

    let result = output.output(text: "Recovered transcript", target: target)

    XCTAssertEqual(result.method, .clipboard)
    XCTAssertNotNil(result.error)
    XCTAssertEqual(pasteboard.string(forType: .string), "Recovered transcript")
  }
  #endif

  // MARK: - Captured field identity (issue #707)

  @MainActor
  private func makeRunningTarget(focusedElement: AXUIElement?) -> TextOutputTarget {
    TextOutputTarget(
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      applicationName: "Tests",
      bundleIdentifier: nil,
      applicationLaunchDate: nil,
      focusedElement: focusedElement
    )
  }

  @MainActor
  func testAccessibilityOutput_capturedTargetWithoutElement_NeverUsesCurrentFocus() {
    let suiteName = "com.speakapp.text-output-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let output = AccessibilityTextOutput(
      permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
      appSettings: AppSettings(defaults: defaults)
    )

    let result = output.output(text: "hello", target: makeRunningTarget(focusedElement: nil))

    XCTAssertEqual(result.method, .none)
    guard case .some(TextOutputError.capturedFieldUnavailable) = result.error else {
      return XCTFail("Expected capturedFieldUnavailable, got \(String(describing: result.error))")
    }
  }

  @MainActor
  func testAccessibilityOutput_elementFromAnotherProcess_IsRefused() {
    let suiteName = "com.speakapp.text-output-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let output = AccessibilityTextOutput(
      permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
      appSettings: AppSettings(defaults: defaults)
    )
    // An element bound to a different process than the captured identity: the
    // capture raced an app switch and must not be delivered into.
    let foreignElement = AXUIElementCreateApplication(1)

    let result = output.output(text: "hello", target: makeRunningTarget(focusedElement: foreignElement))

    XCTAssertEqual(result.method, .none)
    guard case .some(TextOutputError.capturedFieldChanged) = result.error else {
      return XCTFail("Expected capturedFieldChanged, got \(String(describing: result.error))")
    }
  }

  @MainActor
  func testPasteOutput_capturedTargetWithoutElement_UsesApplicationFallbackAndKeepsClipboard() {
    let suiteName = "com.speakapp.text-output-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
    defer {
      pasteboard.clearContents()
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    let settings = AppSettings(defaults: defaults)
    settings.textOutputMethod = .smart
    let output = PasteTextOutput(
      permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
      appSettings: settings,
      pasteboard: pasteboard
    )

    let result = output.output(text: "Withheld transcript", target: makeRunningTarget(focusedElement: nil))

    XCTAssertEqual(result.method, .clipboard)
    if case .some(TextOutputError.capturedFieldUnavailable) = result.error {
      XCTFail("A missing AX field should use the captured-application fallback")
    }
    XCTAssertEqual(pasteboard.string(forType: .string), "Withheld transcript")
  }

  @MainActor
  func testCapturedElementBelongsToCapturedProcess_matchesOnlyItsOwnProcess() {
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let ownElement = AXUIElementCreateApplication(ownPid)

    XCTAssertTrue(makeRunningTarget(focusedElement: ownElement)
      .capturedElementBelongsToCapturedProcess())
    XCTAssertFalse(makeRunningTarget(focusedElement: AXUIElementCreateApplication(1))
      .capturedElementBelongsToCapturedProcess())
    XCTAssertFalse(makeRunningTarget(focusedElement: nil)
      .capturedElementBelongsToCapturedProcess())
  }

  @MainActor
  func testConfirmCapturedFieldOwnsFocus_requiresFrontmostProcessAndIdenticalField() {
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let capturedElement = AXUIElementCreateApplication(ownPid)
    let target = makeRunningTarget(focusedElement: capturedElement)

    // No element captured: identity cannot be proven.
    XCTAssertEqual(
      makeRunningTarget(focusedElement: nil).confirmCapturedFieldOwnsFocus(
        frontmostProcessIdentifier: ownPid,
        currentFocus: { capturedElement }
      ),
      .fieldUnavailable
    )
    // Captured process not frontmost: a paste keystroke would land elsewhere.
    XCTAssertEqual(
      target.confirmCapturedFieldOwnsFocus(
        frontmostProcessIdentifier: 1,
        currentFocus: { capturedElement }
      ),
      .fieldChanged
    )
    // Same process, different field (another conversation in the same app).
    XCTAssertEqual(
      target.confirmCapturedFieldOwnsFocus(
        frontmostProcessIdentifier: ownPid,
        currentFocus: { AXUIElementCreateApplication(1) }
      ),
      .fieldChanged
    )
    // Focus cannot be read at all: fail closed.
    XCTAssertEqual(
      target.confirmCapturedFieldOwnsFocus(
        frontmostProcessIdentifier: ownPid,
        currentFocus: { nil }
      ),
      .fieldChanged
    )
    // The captured field still owns focus in the frontmost captured process.
    XCTAssertEqual(
      target.confirmCapturedFieldOwnsFocus(
        frontmostProcessIdentifier: ownPid,
        currentFocus: { AXUIElementCreateApplication(ownPid) }
      ),
      .confirmed
    )
  }

  @MainActor
  func testCapturedApplicationIsFrontmost_requiresSameRunningProcess() {
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let target = makeRunningTarget(focusedElement: nil)

    XCTAssertTrue(target.capturedApplicationIsFrontmost(frontmostProcessIdentifier: ownPid))
    XCTAssertFalse(target.capturedApplicationIsFrontmost(frontmostProcessIdentifier: 1))
    XCTAssertFalse(target.capturedApplicationIsFrontmost(frontmostProcessIdentifier: nil))
  }

  func testHotKeyMonitoringState_displayNames_AreActionable() {
    XCTAssertEqual(HotKeyMonitoringState.active.displayName, "Active")
    XCTAssertEqual(
      HotKeyMonitoringState.inputMonitoringRequired.displayName,
      "Needs Input Monitoring"
    )
    XCTAssertEqual(HotKeyMonitoringState.registrationFailed.displayName, "Reconnect Required")
  }
}

final class ClipboardFieldIdentityPolicyTests: XCTestCase {
  @MainActor
  func testPasteOutput_changedCapturedField_PastesWithWarningInsteadOfError() {
    let suiteName = "com.speakapp.text-output-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(suiteName))
    defer {
      pasteboard.clearContents()
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    let settings = AppSettings(defaults: defaults)
    settings.textOutputMethod = .smart
    let output = PasteTextOutput(
      permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
      appSettings: settings,
      pasteboard: pasteboard
    )
    let changedTarget = TextOutputTarget(
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      applicationName: "Tests",
      bundleIdentifier: nil,
      applicationLaunchDate: nil,
      focusedElement: AXUIElementCreateApplication(1)
    )

    let result = output.output(text: "Paste despite target warning", target: changedTarget)

    XCTAssertEqual(result.method, .clipboard)
    XCTAssertNil(result.error)
    guard let warning = result.warning as? TextOutputError,
          case .capturedFieldChanged = warning
    else {
      return XCTFail("Expected the changed target to be reported as a warning")
    }
    XCTAssertEqual(pasteboard.string(forType: .string), "Paste despite target warning")
  }

  @MainActor
  func testExactFieldIdentity_isOnlyRequiredForSmartModeWithAccessibility() {
    XCTAssertFalse(
      PasteTextOutput.requiresExactFieldIdentity(
        textOutputMethod: .clipboardOnly,
        accessibilityGranted: true
      )
    )
    XCTAssertFalse(
      PasteTextOutput.requiresExactFieldIdentity(
        textOutputMethod: .smart,
        accessibilityGranted: false
      )
    )
    XCTAssertTrue(
      PasteTextOutput.requiresExactFieldIdentity(
        textOutputMethod: .smart,
        accessibilityGranted: true
      )
    )
  }

  @MainActor
  func testUnavailableFieldFallsBackToFrontmostCapturedApplication() {
    XCTAssertNil(
      PasteTextOutput.fieldIdentityError(
        confirmation: .fieldUnavailable,
        capturedApplicationIsFrontmost: true
      )
    )
    guard case .capturedFieldChanged? = PasteTextOutput.fieldIdentityError(
      confirmation: .fieldUnavailable,
      capturedApplicationIsFrontmost: false
    ) else {
      return XCTFail("A missing field must not paste after the captured app loses focus")
    }
    guard case .capturedFieldChanged? = PasteTextOutput.fieldIdentityError(
      confirmation: .fieldChanged,
      capturedApplicationIsFrontmost: true
    ) else {
      return XCTFail("A positive field change must remain fail-closed")
    }
  }

  @MainActor
  func testChangedFieldIsAWarningPolicyRatherThanBlockingPaste() {
    guard case .capturedFieldChanged? = PasteTextOutput.fieldIdentityError(
      confirmation: .fieldChanged,
      capturedApplicationIsFrontmost: true
    ) else {
      return XCTFail("A changed target should still be surfaced as a delivery warning")
    }
  }
}
