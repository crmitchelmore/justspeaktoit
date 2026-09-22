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
