#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class IOSHistoryRequestFailureOwnershipTests: XCTestCase {
    func testFailureGetterIsExactRunAndResetWithoutRetiringPublishedErrorSnapshot() throws {
        var state = IOSRequestDiagnosticState()
        let first = UUID(), replacement = UUID(), publication = UUID()
        state.begin(first)
        state.admit(IOSRequestFailureValues.context, run: first)
        XCTAssertNil(state.failure(for: first))
        let snapshot = try XCTUnwrap(state.freezeFailure(IOSRequestFailureValues.failure, run: first))
        state.publish(snapshot, token: publication)
        let frozen = try XCTUnwrap(state.failure(for: first))
        XCTAssertNil(state.failure(for: nil))
        XCTAssertNil(state.failure(for: replacement))
        state.retire(first)
        XCTAssertNil(state.failure(for: first))
        XCTAssertEqual(state.snapshot(for: publication).full.jsonData, snapshot.full.jsonData)
        state.begin(replacement)
        XCTAssertNil(state.failure(for: replacement))
        XCTAssertNil(state.freezeFailure(.init(stage: .request), run: first))
        XCTAssertNil(state.failure(for: replacement))
        state.freezeFailure(.init(stage: .request, code: .unavailable), run: replacement)
        XCTAssertEqual(frozen, IOSRequestFailureValues.failure)
        XCTAssertNil(state.failure(for: first))
        XCTAssertEqual(state.failure(for: replacement), .init(stage: .request, code: .unavailable))
        state.retire(first)
        XCTAssertNotNil(state.failure(for: replacement), "Stale retirement must not clear the new owner")
    }

    func testAdmittedPartialHistoryWriteRetainsFrozenFailureAfterReplacementAndCallerCancellation() async throws {
        let fixture = try IOSAdmissionFixture(self)
        let manager = fixture.manager()
        var state = IOSRequestDiagnosticState()
        let first = UUID(), replacement = UUID()
        state.begin(first)
        state.admit(IOSRequestFailureValues.context, run: first)
        // Same typed local watchdog outcome, not an elapsed watchdog/service test.
        state.freezeFailure(IOSRequestFailureValues.failure, run: first)
        let admission = state.admission(for: first)
        let failure = state.failure(for: first)
        state.retire(first)
        let entered = XCTestExpectation(description: "Owned primary partial write held")
        let done = XCTestExpectation(description: "Owned partial caller returned")
        let exit = XCTestExpectation(description: "Owned partial caller exited")
        fixture.storage.holdWrite(entered)
        let task = Task { @MainActor in
            defer { done.fulfill(); exit.fulfill() }
            return await manager.recordTranscriptionAndWait(
                text: "retained partial", model: "deepgram/nova-3-streaming", duration: 1,
                requestContext: admission, requestFailure: failure
            )
        }
        fixture.own(task, exit: exit)
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed else {
            XCTFail("Owned partial History write was not admitted")
            return
        }
        state.begin(replacement)
        state.admit(.init(model: .project("openai/whisper-1"), mode: .batch), run: replacement)
        task.cancel()
        fixture.storage.release()
        guard await XCTWaiter.fulfillment(of: [done], timeout: 2) == .completed else {
            XCTFail("Admitted partial History write did not return")
            return
        }
        let returned = await task.value
        let item = try XCTUnwrap(returned)
        XCTAssertEqual(item.requestFailure, IOSRequestFailureValues.failure)
        XCTAssertEqual(item.requestContext, admission)
        XCTAssertNil(item.errorMessage)
        XCTAssertEqual(try fixture.read().first?.requestFailure, failure)
        XCTAssertEqual(manager.items.first?.requestFailure, failure)
        XCTAssertNil(state.failure(for: replacement))
        XCTAssertFalse(fixture.storage.timedOut)
        XCTAssertFalse(fixture.storage.observedMainThread)
    }

    func testEmptyAndExistingCallsNeverInventFailureRowsOrInheritRetiredOutcome() async throws {
        let fixture = try IOSAdmissionFixture(self)
        let manager = fixture.manager()
        let empty = await manager.recordTranscriptionAndWait(
            text: "  ", model: "owned", duration: 1, requestFailure: IOSRequestFailureValues.failure
        )
        XCTAssertNil(empty)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let legacy = await manager.recordTranscriptionAndWait(text: "legacy", model: "owned", duration: 1)
        let admitted = await manager.recordTranscriptionAndWait(
            text: "admitted", model: "owned", duration: 1, requestContext: IOSRequestFailureValues.context
        )
        XCTAssertNotNil(legacy)
        XCTAssertNotNil(admitted)
        XCTAssertNil(legacy?.requestFailure)
        XCTAssertNil(admitted?.requestFailure)
        XCTAssertTrue(try fixture.read().allSatisfy { $0.requestFailure == nil })
    }
}
#endif
