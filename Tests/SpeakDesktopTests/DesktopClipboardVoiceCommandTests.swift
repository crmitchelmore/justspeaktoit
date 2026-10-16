import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopClipboardVoiceCommandTests: XCTestCase {
    func testOrdinaryTextAndDisabledCommandsNeverInvokeTheNativeReader() async throws {
        for (text, enabled) in [("ordinary words", true), ("copypastas", true), ("copy pasta", false)] {
            let result = try await DesktopClipboardVoiceCommands.process(
                text, policy: ClipboardVoiceCommandPolicy(isEnabled: enabled, customTriggers: "")
            ) {
                XCTFail("Unrecognized or disabled text must not probe the clipboard")
                throw DesktopClipboardReadError.unsupported("Synthetic unexpected read")
            }
            XCTAssertEqual(result, text)
        }
    }

    func testMultipleCommandsUseOneReadAndCanonicalExpansion() async throws {
        let probe = ClipboardReadProbe(value: "SYNTHETIC")
        let result = try await DesktopClipboardVoiceCommands.process(
            "paste clipboard then copy pasta", policy: .init(isEnabled: true, customTriggers: "paste")
        ) { await probe.read() }
        XCTAssertEqual(result, "SYNTHETIC then SYNTHETIC")
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    func testAbsentAndEmptyTextPreserveTheCanonicalRecognizedCommand() async throws {
        for text: String? in [nil, ""] {
            let probe = ClipboardReadProbe(value: text)
            let result = try await DesktopClipboardVoiceCommands.process(
                "copy pasta", policy: .init(isEnabled: true, customTriggers: "")
            ) { await probe.read() }
            XCTAssertEqual(result, "copy pasta")
            let calls = await probe.calls
            XCTAssertEqual(calls, 1)
        }
    }

    func testDeniedOrUnsupportedReadIsNotSilentlyReturnedAsSuccessfulText() async {
        let expected = DesktopClipboardReadError.unsupported("Synthetic denied read")
        do {
            _ = try await DesktopClipboardVoiceCommands.process(
                "copy pasta", policy: .init(isEnabled: true, customTriggers: "")
            ) { throw expected }
            XCTFail("Read failure must reach the host")
        } catch {
            XCTAssertEqual(error as? DesktopClipboardReadError, expected)
        }
    }

    func testReadLimitMeasuresUTF8BytesNotCharacters() async throws {
        let maximum = DesktopClipboardVoiceCommands.maximumClipboardUTF8Bytes
        let accepted = String(repeating: "\u{00E9}", count: maximum / 2)
        let result = try await DesktopClipboardVoiceCommands.process(
            "copy pasta", policy: .init(isEnabled: true, customTriggers: "")
        ) { accepted }
        XCTAssertEqual(result.utf8.count, maximum)
        let rejected = accepted + "\u{00E9}"
        do {
            _ = try await DesktopClipboardVoiceCommands.process(
                "copy pasta", policy: .init(isEnabled: true, customTriggers: "")
            ) { rejected }
            XCTFail("Oversized read must fail")
        } catch {
            XCTAssertEqual(error as? DesktopClipboardReadError, .tooLarge)
        }
    }

    func testPolicyIsImmutableWhileClipboardContentIsReadAtFinalization() async throws {
        var triggers = "my clipboard"
        let policy = ClipboardVoiceCommandPolicy(isEnabled: true, customTriggers: triggers)
        triggers = "changed command"
        let probe = ClipboardReadProbe(value: "CURRENT SYNTHETIC CONTENT")
        let result = try await DesktopClipboardVoiceCommands.process("my clipboard", policy: policy) {
            await probe.read()
        }
        XCTAssertEqual(result, "CURRENT SYNTHETIC CONTENT")
        XCTAssertEqual(policy.customTriggers, "my clipboard")
        XCTAssertEqual(triggers, "changed command")
    }

    func testCancellationFencesAReadThatReturnsLate() async {
        let gate = ClipboardReadGate()
        let entered = expectation(description: "Synthetic read entered")
        let task = Task {
            try await DesktopClipboardVoiceCommands.process(
                "copy pasta", policy: .init(isEnabled: true, customTriggers: "")
            ) {
                entered.fulfill()
                return await gate.read()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.complete("UNTRUSTED LATE TEXT")
        do {
            _ = try await task.value
            XCTFail("Cancelled operation cannot publish expanded text")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAlreadyCancelledProcessingNeverReadsClipboard() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DesktopClipboardVoiceCommands.process(
                "copy pasta", policy: .init(isEnabled: true, customTriggers: "")
            ) {
                XCTFail("A cancelled command must not access the clipboard")
                return "UNEXPECTED SYNTHETIC CONTENT"
            }
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled operation cannot return transformed text")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private actor ClipboardReadProbe {
    let value: String?
    private(set) var calls = 0
    init(value: String?) { self.value = value }
    func read() -> String? { calls += 1; return value }
}

private actor ClipboardReadGate {
    private var continuation: CheckedContinuation<String?, Never>?
    private var completed = false
    private var value: String?

    func read() async -> String? {
        if completed { return value }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete(_ text: String?) {
        completed = true
        value = text
        continuation?.resume(returning: text)
        continuation = nil
    }
}
