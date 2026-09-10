#if os(iOS)
import UIKit
import XCTest

@testable import SpeakiOSLib

@MainActor
final class AutomaticPolishOperationTests: XCTestCase {
    func testSuccessfulPolishKeepsRawClipboardAndSavesHistory() async {
        let fixture = Fixture()
        fixture.clipboard.copyRaw("raw")
        XCTAssertEqual(fixture.pasteboard.writes, ["raw"])
        let operation = fixture.operation()
        operation.start { "polished" }
        await fixture.settle()
        XCTAssertEqual(fixture.pasteboard.writes, ["raw"])
        XCTAssertEqual(fixture.history[fixture.currentID], "polished")
        XCTAssertEqual(fixture.latest, "polished")
    }

    func testInterveningDifferentIdenticalAndNonTextCopiesArePreserved() async {
        for copied in ["new", "raw", nil] as [String?] {
            let fixture = Fixture()
            fixture.clipboard.copyRaw("raw")
            let processor = Processor()
            let operation = fixture.operation()
            operation.start { try await processor.run() }
            await processor.waitUntilStarted()
            fixture.pasteboard.copyFromAnotherApp(copied)
            processor.continuation?.resume(returning: "polished")
            await fixture.settle()
            XCTAssertEqual(fixture.pasteboard.string, copied)
            XCTAssertEqual(fixture.pasteboard.writes, ["raw"])
            XCTAssertEqual(fixture.history[fixture.currentID], "polished")
        }
    }

    func testInitialWriteNeverRetriesAfterAnotherCopy() async {
        let fixture = Fixture()
        fixture.pasteboard.afterWrite = { fixture.pasteboard.copyFromAnotherApp("new") }
        fixture.clipboard.copyRaw("raw")
        let operation = fixture.operation()
        operation.start { "polished" }
        await fixture.settle()
        XCTAssertEqual(fixture.pasteboard.writes, ["raw"])
        XCTAssertEqual(fixture.pasteboard.string, "new")
        XCTAssertEqual(fixture.history[fixture.currentID], "polished")
    }

    func testFailureNeverRestoresRawOverNewCopy() async {
        let fixture = Fixture()
        fixture.clipboard.copyRaw("raw")
        fixture.pasteboard.copyFromAnotherApp("new")
        let operation = fixture.operation()
        operation.start { throw URLError(.timedOut) }
        await fixture.settle()
        XCTAssertEqual(fixture.pasteboard.string, "new")
        XCTAssertEqual(fixture.errors, 1)
    }

    func testCancelledProviderReturningSuccessHasNoLateSideEffects() async {
        let fixture = Fixture()
        fixture.clipboard.copyRaw("raw")
        let processor = Processor()
        let operation = fixture.operation()
        operation.start { try await processor.run() }
        await processor.waitUntilStarted()
        operation.cancel()
        XCTAssertTrue(fixture.processing.isEmpty)
        fixture.pasteboard.copyFromAnotherApp("new")
        processor.continuation?.resume(returning: "polished despite cancellation")
        for _ in 0..<1_000 where !processor.returned { await Task.yield() }
        XCTAssertTrue(processor.returned)
        await Task.yield()
        XCTAssertEqual(fixture.pasteboard.string, "new")
        XCTAssertTrue(fixture.history.isEmpty)
        XCTAssertEqual(fixture.latest, "raw")
        XCTAssertEqual(fixture.completions, 1)
    }

    func testOutOfOrderCompletionsKeepOwnHistoryAndNewLatestResult() async {
        let fixture = Fixture()
        let oldID = fixture.currentID
        fixture.clipboard.copyRaw("old raw")
        let old = fixture.operation()
        let processor = Processor()
        old.start { try await processor.run() }
        await processor.waitUntilStarted()
        fixture.currentID = UUID()
        fixture.clipboard.copyRaw("new raw")
        let new = fixture.operation()
        new.start { "new polished" }
        await fixture.settle()
        processor.continuation?.resume(returning: "old polished")
        await fixture.settle(completions: 2)
        XCTAssertEqual(fixture.history[oldID], "old polished")
        XCTAssertEqual(fixture.history[fixture.currentID], "new polished")
        XCTAssertEqual(fixture.latest, "new polished")
        XCTAssertEqual(fixture.pasteboard.string, "new raw")
        XCTAssertEqual(fixture.pasteboard.writes, ["old raw", "new raw"])
    }

    func testExpirationBeforeTaskInstallationEndsAssertionExactlyOnce() async {
        let fixture = Fixture()
        var ends = 0
        let assertion = BackgroundTaskAssertion(
            name: "test",
            begin: { _, expire in
                expire()
                return UIBackgroundTaskIdentifier(rawValue: 42)
            },
            end: { _ in ends += 1 }
        )
        fixture.clipboard.copyRaw("raw")
        let operation = fixture.operation()
        var processed = false
        operation.start(under: assertion, isActive: true) { processed = true; return "polished" }
        await Task.yield()
        assertion.end()
        XCTAssertFalse(processed)
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(fixture.completions, 1)
        XCTAssertFalse(assertion.isValid)
    }

    func testExpirationDuringProviderCancelsAndSettlesImmediately() async {
        let fixture = Fixture()
        var expire: (() -> Void)?
        var ends = 0
        let assertion = BackgroundTaskAssertion(
            name: "test",
            begin: { _, handler in
                expire = handler
                return UIBackgroundTaskIdentifier(rawValue: 42)
            },
            end: { _ in ends += 1 }
        )
        fixture.clipboard.copyRaw("raw")
        let operation = fixture.operation()
        let processor = Processor()
        operation.start(under: assertion, isActive: false) { try await processor.run() }
        await processor.waitUntilStarted()
        expire?()
        XCTAssertTrue(fixture.processing.isEmpty)
        XCTAssertEqual(fixture.completions, 1)
        XCTAssertEqual(ends, 1)
        processor.continuation?.resume(returning: "late")
        for _ in 0..<1_000 where !processor.returned { await Task.yield() }
        XCTAssertTrue(processor.returned)
        await Task.yield()
        assertion.end()
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(fixture.pasteboard.string, "raw")
        XCTAssertTrue(fixture.history.isEmpty)
    }

    func testUnavailableAssertionAndCancelledBeforeStartDoNotRunProcessor() async {
        let fixture = Fixture()
        let assertion = BackgroundTaskAssertion(name: "test", begin: { _, _ in .invalid }, end: { _ in
            XCTFail("Must not end an invalid assertion")
        })
        XCTAssertFalse(assertion.isValid)
        fixture.clipboard.copyRaw("raw")
        let operation = fixture.operation()
        operation.start(under: assertion, isActive: false) {
            XCTFail("Operation ran without background assertion")
            return "late"
        }
        await Task.yield()
        assertion.end()
        XCTAssertEqual(fixture.completions, 1)
        XCTAssertEqual(fixture.pasteboard.writes, ["raw"])
    }

    func testEmptyRawDoesNotTouchClipboard() {
        let fixture = Fixture()
        fixture.clipboard.copyRaw("")
        XCTAssertTrue(fixture.pasteboard.writes.isEmpty)
    }
}
private extension AutomaticPolishOperationTests {
    @MainActor
    private final class Pasteboard: PolishPasteboard {
        var string: String?
        var writes: [String] = []
        var afterWrite: (() -> Void)?

        func write(_ text: String) {
            string = text
            writes.append(text)
            afterWrite?()
        }

        func copyFromAnotherApp(_ text: String?) {
            string = text
        }
    }

    @MainActor
    private final class Processor {
        var continuation: CheckedContinuation<String, Error>?
        var returned = false

        func run() async throws -> String {
            let result = try await withCheckedThrowingContinuation { continuation = $0 }
            returned = true
            return result
        }

        func waitUntilStarted() async {
            for _ in 0..<1_000 where continuation == nil { await Task.yield() }
            XCTAssertNotNil(continuation)
        }
    }

    @MainActor
    private final class Fixture {
        let pasteboard = Pasteboard()
        var currentID = UUID()
        var latest = "raw"
        var history: [UUID: String] = [:]
        var errors = 0
        var completions = 0
        var processing: Set<UUID> = []
        lazy var clipboard = PolishClipboard(pasteboard: pasteboard)

        func operation() -> AutomaticPolishOperation {
            let operationID = currentID
            processing.insert(operationID)
            return AutomaticPolishOperation(
                isCurrent: { self.currentID == operationID },
                success: { text, current in
                    self.history[operationID] = text
                    if current { self.latest = text }
                },
                failure: { _ in self.errors += 1 },
                completion: {
                    self.processing.remove(operationID)
                    self.completions += 1
                }
            )
        }

        func settle(completions expected: Int = 1) async {
            for _ in 0..<1_000 where completions < expected { await Task.yield() }
            XCTAssertEqual(completions, expected)
        }
    }

}
#endif
