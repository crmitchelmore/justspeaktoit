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

  func testHotKeyMonitoringState_displayNames_AreActionable() {
    XCTAssertEqual(HotKeyMonitoringState.active.displayName, "Active")
    XCTAssertEqual(
      HotKeyMonitoringState.inputMonitoringRequired.displayName,
      "Needs Input Monitoring"
    )
    XCTAssertEqual(HotKeyMonitoringState.registrationFailed.displayName, "Reconnect Required")
  }
}
