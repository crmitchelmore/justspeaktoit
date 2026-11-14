import Foundation
import SpeakDesktop
import XCTest

final class DesktopVoiceEditTargetTests: XCTestCase {
    private final class FakeTarget: DesktopVoiceEditTarget, @unchecked Sendable {
        private let lock = NSLock()
        var selection = "teh draft"
        var current = true
        var replacement = DesktopVoiceEditReplacement.replaced
        var copyFails = false
        private(set) var replaced: [String] = []
        private(set) var copied: [String] = []

        var isCurrent: Bool { lock.withLock { current } }

        func selectedText() async throws -> String { lock.withLock { selection } }

        func replace(with text: String) async -> DesktopVoiceEditReplacement {
            lock.withLock {
                replaced.append(text)
                return replacement
            }
        }

        func copyToClipboard(_ text: String) throws {
            try lock.withLock {
                if copyFails { throw DesktopVoiceEditTargetError("Clipboard refused.") }
                copied.append(text)
            }
        }

        func cancel() {}
    }

    private let unavailable = "No fresh selection target is available."

    func testCapture_noSelectionTarget_throwsUnavailableMessage() async {
        do {
            _ = try await DesktopVoiceEditDelivery.capture(nil, unavailable: unavailable)
            XCTFail("A missing target must not capture anything.")
        } catch {
            XCTAssertEqual(error.localizedDescription, unavailable)
        }
    }

    func testCapture_emptySelection_throwsEmptyInput() async {
        let target = FakeTarget()
        target.selection = ""
        do {
            _ = try await DesktopVoiceEditDelivery.capture(target, unavailable: unavailable)
            XCTFail("An empty selection must not start a voice edit.")
        } catch {
            XCTAssertTrue(error is DesktopVoiceEditError)
        }
    }

    func testReplace_success_replacesCapturedTargetOnce() async throws {
        let target = FakeTarget()
        let selection = try await DesktopVoiceEditDelivery.capture(target, unavailable: unavailable)
        let outcome = try await DesktopVoiceEditDelivery.replace("the draft", target: target, unavailable: unavailable)

        XCTAssertEqual(selection, "teh draft")
        XCTAssertEqual(outcome, .replaced(DesktopVoiceEditDelivery.replacedStatus))
        XCTAssertEqual(target.replaced, ["the draft"])
        XCTAssertTrue(target.copied.isEmpty)
    }

    func testReplace_targetChanged_neverReplacesAndCopiesRewrite() async throws {
        let target = FakeTarget()
        target.current = false
        let outcome = try await DesktopVoiceEditDelivery.replace("the draft", target: target, unavailable: unavailable)

        XCTAssertTrue(target.replaced.isEmpty)
        XCTAssertEqual(target.copied, ["the draft"])
        XCTAssertEqual(outcome, .recovery(
            "Voice edit was not applied. Rewrite copied for manual paste. \(DesktopVoiceEditDelivery.targetChanged)"
        ))
    }

    func testReplace_refusedAtFinalCheck_reportsNotApplied() async throws {
        let target = FakeTarget()
        target.replacement = .refused("The selection moved.")
        let outcome = try await DesktopVoiceEditDelivery.replace("the draft", target: target, unavailable: unavailable)

        XCTAssertEqual(target.replaced, ["the draft"])
        XCTAssertEqual(outcome, .recovery(
            "Voice edit was not applied. Rewrite copied for manual paste. The selection moved."
        ))
    }

    func testReplace_indeterminate_warnsItMayHaveReachedTheApp() async throws {
        let target = FakeTarget()
        target.replacement = .indeterminate("Replacement was not confirmed.")
        let outcome = try await DesktopVoiceEditDelivery.replace("the draft", target: target, unavailable: unavailable)

        XCTAssertEqual(target.replaced, ["the draft"])
        XCTAssertEqual(outcome, .recovery(
            "Voice edit may have reached the app. Rewrite copied; check the original before pasting. "
                + "Replacement was not confirmed."
        ))
    }

    func testReplace_recoveryCopyFails_throwsWithReason() async {
        let target = FakeTarget()
        target.replacement = .indeterminate("Replacement was not confirmed.")
        target.copyFails = true
        do {
            _ = try await DesktopVoiceEditDelivery.replace("the draft", target: target, unavailable: unavailable)
            XCTFail("A lost rewrite must be reported as a failure.")
        } catch let error as DesktopVoiceEditTargetError {
            XCTAssertTrue(error.mayHaveReplaced)
            XCTAssertEqual(
                error.message,
                "Replacement was not confirmed. The rewrite could not be copied either: Clipboard refused."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
