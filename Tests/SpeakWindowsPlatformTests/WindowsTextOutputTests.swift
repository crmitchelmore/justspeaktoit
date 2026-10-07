#if os(Windows)
import CWindowsSupport
import XCTest
@testable import SpeakWindowsPlatform

final class WindowsTextOutputTests: XCTestCase {
    /// Synthetic hidden controls, an in-memory clipboard and a keystroke stub:
    /// caret/selection insertion, surrogate pairs, stale identity, password and
    /// read-only refusal, UI Automation value/paste paths, timeouts and worker
    /// cleanup. Never sends real input or touches the system clipboard.
    func testSyntheticInsertionSelfTest_PassesWithoutTouchingTheDesktop() {
        var error = [CChar](repeating: 0, count: 1_024)
        XCTAssertEqual(jsti_text_output_self_test(&error, error.count), 0, String(cString: error))
    }

    /// Target-independent clipboard output on an in-memory clipboard: copy,
    /// cancellation before and inside the owned section, single use and
    /// failed-write restore, with no focus query or input.
    func testClipboardOutputSelfTest_PassesWithoutTouchingTheSystemClipboard() {
        var error = [CChar](repeating: 0, count: 1_024)
        XCTAssertEqual(jsti_clipboard_output_self_test(&error, error.count), 0, String(cString: error))
    }

    /// Both refusals happen before the clipboard is opened, so this never
    /// reads or writes the system clipboard.
    func testClipboardOutput_RefusesCancelledAndUsedJobsBeforeOpeningTheClipboard() throws {
        let cancelled = try WindowsClipboardOutput()
        cancelled.cancel()
        XCTAssertThrowsError(try cancelled.copy("transcript")) { error in
            XCTAssertTrue((error as? WindowsTextOutputError)?.message.contains("cancelled") == true)
            XCTAssertEqual((error as? WindowsTextOutputError)?.clipboard, .untouched)
        }
        let used = try WindowsClipboardOutput()
        XCTAssertThrowsError(try used.copy(""))
        XCTAssertThrowsError(try used.copy("transcript")) { error in
            XCTAssertTrue((error as? WindowsTextOutputError)?.message.contains("already used") == true)
        }
    }

    /// A C string ends at NUL, so a transcript containing one is refused before
    /// the native job runs instead of being reported as copied after only its
    /// prefix. Neither request reaches the system clipboard.
    func testClipboardOutput_RefusesEmbeddedNULBeforeTheNativeJobRuns() throws {
        let output = try WindowsClipboardOutput()
        XCTAssertThrowsError(try output.copy("first\u{0}last")) { error in
            XCTAssertTrue((error as? WindowsTextOutputError)?.message.contains("NUL") == true)
            XCTAssertEqual((error as? WindowsTextOutputError)?.clipboard, .untouched)
        }
        // The job is still unused: an empty request reaches the native text check.
        XCTAssertThrowsError(try output.copy("")) { error in
            XCTAssertTrue((error as? WindowsTextOutputError)?.message.contains("no transcript") == true)
        }
    }

    func testNativeChoice_RoundTripsEveryCombinationWithStableValues() {
        let methods: [(WindowsTextOutputOptions.Method, Int32)] = [(.smart, 0), (.directOnly, 1), (.clipboardOnly, 2)]
        let insertions: [(WindowsTextOutputOptions.Insertion, Int32)] = [(.insertAtCursor, 0), (.replaceField, 1)]
        for (method, methodValue) in methods {
            for (insertion, insertionValue) in insertions {
                for restore in [false, true] {
                    let options = WindowsTextOutputOptions(
                        method: method, insertion: insertion, restoreClipboard: restore
                    )
                    let expected = WindowsTextOutputNativeChoice(
                        method: methodValue, insertion: insertionValue, restoreClipboard: restore ? 1 : 0
                    )
                    XCTAssertEqual(options.nativeChoice, expected)
                    XCTAssertEqual(WindowsTextOutputOptions(nativeChoice: expected), options)
                }
            }
        }
        XCTAssertEqual(Int32(JSTI_TEXT_OUTPUT_SMART.rawValue), 0)
        XCTAssertEqual(Int32(JSTI_TEXT_OUTPUT_DIRECT_ONLY.rawValue), 1)
        XCTAssertEqual(Int32(JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY.rawValue), 2)
        XCTAssertEqual(Int32(JSTI_TEXT_OUTPUT_AT_CURSOR.rawValue), 0)
        XCTAssertEqual(Int32(JSTI_TEXT_OUTPUT_REPLACE_FIELD.rawValue), 1)
        XCTAssertEqual(WindowsTextOutputOptions().nativeChoice, .init(method: 0, insertion: 0, restoreClipboard: 1))
    }

    func testNativeChoice_RejectsValuesOutsideTheContract() {
        let invalid: [[Int32]] = [[3, 0, 1], [-1, 0, 1], [0, 2, 1], [0, -1, 1], [0, 0, 2], [0, 0, -1]]
        for values in invalid {
            let choice = WindowsTextOutputNativeChoice(
                method: values[0], insertion: values[1], restoreClipboard: values[2]
            )
            XCTAssertNil(WindowsTextOutputOptions(nativeChoice: choice), "\(values)")
        }
    }

    /// Configuration is valid before any window exists; a rejected value
    /// never replaces the dialog's previous choices.
    func testDialogConfiguration_RejectsInvalidValuesWithoutReplacingTheLastChoice() {
        let callback: JSTITextOutputSettingsCallback = { _, _, _, _ in }
        XCTAssertEqual(jsti_window_set_text_output(2, 1, 0, callback, nil), 0)
        XCTAssertEqual(jsti_window_set_text_output(3, 0, 1, callback, nil), -1)
        XCTAssertEqual(jsti_window_set_text_output(0, 2, 1, callback, nil), -1)
        XCTAssertEqual(jsti_window_set_text_output(0, 0, 2, callback, nil), -1)
        XCTAssertEqual(jsti_window_set_text_output(0, 0, 1, nil, nil), -1)
        var method: Int32 = -1, insertion: Int32 = -1, restore: Int32 = -1
        XCTAssertEqual(jsti_window_text_output(&method, &insertion, &restore), 0)
        XCTAssertEqual([method, insertion, restore], [2, 1, 0])
        XCTAssertEqual(jsti_window_text_output(nil, &insertion, &restore), -1)
        jsti_window_clear_text_output()
        XCTAssertEqual(jsti_window_text_output(&method, &insertion, &restore), -1)
    }

    func testInsertWithoutCapturedTarget_FailsClosed() {
        var result = JSTIInsertionResult()
        result.method = 99
        var error = [CChar](repeating: 0, count: 1_024)
        XCTAssertEqual(jsti_insertion_insert(nil, "text", 0, &result, &error, error.count), -1)
        XCTAssertEqual(result.method, Int32(JSTI_INSERTION_METHOD_NONE.rawValue))
        XCTAssertEqual(result.clipboard, Int32(JSTI_INSERTION_CLIPBOARD_UNTOUCHED.rawValue))
        XCTAssertFalse(String(cString: error).isEmpty)
        jsti_insertion_destroy(nil)
    }

    func testLegacyTargetWithoutWindow_IsRejected() {
        var target = JSTITextTarget()
        var error = [CChar](repeating: 0, count: 1_024)
        XCTAssertEqual(jsti_target_insert_text(&target, "text", &error, error.count), -1)
        XCTAssertFalse(String(cString: error).isEmpty)
    }

    func testOptions_DefaultToSmartInsertAtCursorWithRestore() throws {
        let decoded = try JSONDecoder().decode(WindowsTextOutputOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, WindowsTextOutputOptions())
        XCTAssertEqual(decoded.nativeFlags, 0)
        let unknown = try JSONDecoder().decode(
            WindowsTextOutputOptions.self,
            from: Data(#"{"method":"telepathy","insertion":"replaceField","restoreClipboard":false}"#.utf8)
        )
        XCTAssertEqual(unknown.method, .smart)
        XCTAssertEqual(unknown.insertion, .replaceField)
        XCTAssertFalse(unknown.restoreClipboard)
    }

    func testOptions_MapToNativeFlags() {
        let replace = WindowsTextOutputOptions(insertion: .replaceField)
        XCTAssertEqual(replace.nativeFlags, UInt32(JSTI_INSERTION_REPLACE_FIELD.rawValue))
        let keep = WindowsTextOutputOptions(restoreClipboard: false)
        XCTAssertEqual(keep.nativeFlags, UInt32(JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD.rawValue))
        let direct = WindowsTextOutputOptions(method: .directOnly)
        XCTAssertEqual(direct.nativeFlags, UInt32(JSTI_INSERTION_NO_PASTE_FALLBACK.rawValue))
        let all = WindowsTextOutputOptions(method: .directOnly, insertion: .replaceField, restoreClipboard: false)
        XCTAssertEqual(
            all.nativeFlags,
            UInt32(JSTI_INSERTION_REPLACE_FIELD.rawValue) | UInt32(JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD.rawValue)
                | UInt32(JSTI_INSERTION_NO_PASTE_FALLBACK.rawValue)
        )
        let roundTrip = try? JSONDecoder().decode(WindowsTextOutputOptions.self, from: JSONEncoder().encode(all))
        XCTAssertEqual(roundTrip, all)
    }

    func testUncertainInsertion_DoesNotRecommendAnImmediateRetry() {
        let failure = WindowsTextOutputError(
            "Only part of the shortcut was submitted.", clipboard: .transcriptLeft, mayHaveInserted: true
        )
        let status = WindowsInsertionStatus.message(for: failure)
        XCTAssertTrue(status.contains("could not be confirmed"))
        XCTAssertTrue(status.contains("Check the original field before trying again"))
        XCTAssertFalse(status.contains("select Copy"))
        XCTAssertTrue(status.contains("remains on the clipboard"))
    }

    func testStatusMessages_DescribeMethodVerificationAndClipboard() {
        typealias Outcome = WindowsInsertionTarget.Outcome
        let native = Outcome(method: .nativeEdit, verified: true, fieldIdentity: false, clipboard: .untouched)
        XCTAssertEqual(
            WindowsInsertionStatus.message(for: native), "Inserted into the original text field and saved to History."
        )
        let unverifiedValue = Outcome(
            method: .automationValue, verified: false, fieldIdentity: true, clipboard: .untouched
        )
        XCTAssertTrue(WindowsInsertionStatus.message(for: unverifiedValue).contains("could not be read back"))
        let paste = Outcome(method: .paste, verified: true, fieldIdentity: true, clipboard: .restored)
        XCTAssertEqual(
            WindowsInsertionStatus.message(for: paste),
            "Pasted into the original text field and saved to History. Your previous clipboard content was restored."
        )
        let unconfirmed = Outcome(method: .paste, verified: false, fieldIdentity: true, clipboard: .transcriptLeft)
        let message = WindowsInsertionStatus.message(for: unconfirmed)
        XCTAssertTrue(message.contains("could not be confirmed"))
        XCTAssertTrue(message.contains("remains on the clipboard"))
        let failure = WindowsTextOutputError(
            "The focused field is a password field; automatic insertion is refused.", clipboard: .restoreFailed
        )
        let failureMessage = WindowsInsertionStatus.message(for: failure)
        XCTAssertTrue(failureMessage.hasPrefix(
            "Saved. Automatic insertion unavailable; select Copy. The focused field is a password field"
        ))
        XCTAssertTrue(failureMessage.contains("could not be restored"))
        let restoredFailure = WindowsTextOutputError(
            "The original text field is no longer focused.", clipboard: .restored
        )
        XCTAssertFalse(WindowsInsertionStatus.message(for: restoredFailure).contains("clipboard"))
    }
}
#endif
