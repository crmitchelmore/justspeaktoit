#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class IOSHistoryAdmissionOwnershipTests: XCTestCase {
    func testFrozenAdmissionSurvivesRetirementButGetterNeverReadsReplacementRun() throws {
        var state = IOSRequestDiagnosticState()
        let first = UUID(), replacement = UUID()
        let original = RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        state.begin(first)
        state.admit(original, run: first)
        let frozen = try XCTUnwrap(state.admission(for: first))
        XCTAssertNil(state.admission(for: nil))
        XCTAssertNil(state.admission(for: replacement))
        state.retire(first)
        XCTAssertNil(state.admission(for: first))
        state.begin(replacement)
        let newer = RequestDiagnosticContext(model: .project("deepgram/nova-3-streaming"), mode: .live)
        state.admit(newer, run: replacement)
        XCTAssertEqual(frozen, original)
        XCTAssertNil(state.admission(for: first))
        XCTAssertEqual(state.admission(for: replacement), newer)
        state.admit(.init(provenance: .observedHandoff), run: replacement)
        XCTAssertEqual(state.admission(for: replacement), newer)
    }

    func testActualAdmittedHistoryWriteKeepsFrozenRunAfterReplacementAndCallerCancellation() async throws {
        let fixture = try IOSAdmissionFixture(self)
        let manager = fixture.manager()
        var state = IOSRequestDiagnosticState()
        let first = UUID(), replacement = UUID()
        let original = RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        state.begin(first)
        state.admit(original, run: first)
        // This is the exact production ordering: freeze before completeRun retires.
        let frozen = state.admission(for: first)
        state.retire(first)
        let entered = XCTestExpectation(description: "Owned primary History write held")
        fixture.storage.holdWrite(entered)
        let done = XCTestExpectation(description: "Owned History caller returned")
        let exit = XCTestExpectation(description: "Owned History caller exited")
        let task = Task { @MainActor in
            defer { done.fulfill(); exit.fulfill() }
            return await manager.recordTranscriptionAndWait(
                text: "synthetic text", model: "openai/whisper-1", duration: 1, requestContext: frozen
            )
        }
        fixture.own(task, exit: exit)
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed else {
            XCTFail("Owned write was not admitted")
            return
        }
        state.begin(replacement)
        state.admit(.init(model: .project("deepgram/nova-3-streaming"), mode: .live), run: replacement)
        task.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        fixture.storage.release()
        guard await XCTWaiter.fulfillment(of: [done], timeout: 2) == .completed else {
            XCTFail("Admitted History write did not return")
            return
        }
        let returned = await task.value
        let item = try XCTUnwrap(returned)
        XCTAssertEqual(item.requestContext, original)
        XCTAssertEqual(try fixture.read().first?.requestContext, original)
        XCTAssertEqual(manager.items.first?.requestContext, original)
        XCTAssertNotEqual(state.admission(for: replacement), original)
        XCTAssertNil(item.requestContext?.observedProvider)
        XCTAssertFalse(fixture.storage.timedOut)
        XCTAssertFalse(fixture.storage.observedMainThread)
    }

    func testEmptyAndLegacyCallsDoNotInventRowsOrContextAndHandoffIsRejected() async throws {
        let fixture = try IOSAdmissionFixture(self)
        let manager = fixture.manager()
        let admission = RequestDiagnosticContext(mode: .batch)
        let empty = await manager.recordTranscriptionAndWait(text: "  ", model: "owned", duration: 1,
                                                              requestContext: admission)
        XCTAssertNil(empty)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let old = await manager.recordTranscriptionAndWait(text: "legacy", model: "owned", duration: 1)
        XCTAssertNil(old?.requestContext)
        let rejected = await manager.recordTranscriptionAndWait(
            text: "owned", model: "owned", duration: 1, requestContext: .init(provenance: .observedHandoff)
        )
        XCTAssertNotNil(rejected)
        XCTAssertNil(rejected?.requestContext)
        XCTAssertTrue(try fixture.read().allSatisfy { $0.requestContext == nil })
    }
}
#endif
