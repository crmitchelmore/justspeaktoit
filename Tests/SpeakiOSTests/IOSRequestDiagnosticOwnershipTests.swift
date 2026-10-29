#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class IOSRequestDiagnosticOwnershipTests: XCTestCase {
    func testFrozenErrorRetainsRunAWhileRunBStartsAndChangesSelection() throws {
        var owner = IOSRequestDiagnosticState()
        let first = UUID(), second = UUID(), token = UUID()
        owner.begin(first)
        owner.admit(.init(model: .project("gladia/solaria-1-streaming")), run: first)
        let frozen = try XCTUnwrap(owner.freezeFailure(.init(stage: .request), run: first))
        owner.publish(frozen, token: token)
        owner.retire(first)
        owner.begin(second)
        owner.admit(.init(model: .project("custom/CANARY-new-selection")), run: second)
        let payload = try object(owner.snapshot(for: token))
        XCTAssertEqual(model(payload["context"]), "gladia/solaria-1-streaming")
        XCTAssertFalse(owner.snapshot(for: token).full.jsonString.contains("CANARY"))
    }

    func testRetiredAndReplacedRunsCannotAddHandoffOrFreezeAFailure() throws {
        var owner = IOSRequestDiagnosticState()
        let first = UUID(), second = UUID()
        owner.begin(first)
        owner.retire(first)
        owner.begin(second)
        owner.admit(.init(model: .project("gladia/solaria-1-streaming")), run: first)
        owner.observe(.init(modelID: "gladia/solaria-1-streaming", backend: .shared(.gladia), route: nil),
                      run: first, defaultSession: true)
        XCTAssertNil(owner.freezeFailure(.init(), run: first))
        let snapshot = try XCTUnwrap(owner.freezeFailure(.init(), run: second))
        XCTAssertNil(try object(snapshot)["context"])
        XCTAssertNil(try object(snapshot)["observedHandoff"])
    }

    func testInjectedSessionDoesNotBecomeAnObservedProviderOrHandoff() throws {
        var owner = IOSRequestDiagnosticState()
        let run = UUID()
        owner.begin(run)
        owner.observe(.init(modelID: "gladia/solaria-1-streaming", backend: .shared(.gladia), route: nil),
                      run: run, defaultSession: false)
        let snapshot = try XCTUnwrap(owner.freezeFailure(.init(), run: run))
        XCTAssertNil(try object(snapshot)["observedHandoff"])
    }

    func testDefaultSessionResolutionIsSeparateFromAdmissionAndAlwaysProviderUnknown() throws {
        var owner = IOSRequestDiagnosticState()
        let run = UUID()
        owner.begin(run)
        owner.admit(.init(model: .project("gladia/solaria-1-streaming")), run: run)
        owner.observe(.init(modelID: "openai/gpt-4o-transcribe", backend: .batch, route: nil),
                      run: run, defaultSession: true)
        let payload = try object(try XCTUnwrap(owner.freezeFailure(.init(stage: .request), run: run)))
        XCTAssertEqual(model(payload["context"]), "gladia/solaria-1-streaming")
        XCTAssertEqual(model(payload["observedHandoff"]), "openai/gpt-4o-transcribe")
        XCTAssertNil((payload["observedHandoff"] as? [String: Any])?["observedProvider"])
    }

    func testGenericPublicationClearsPreviousRequestAndOnlyExactTokenCanReadEpisode() throws {
        var owner = IOSRequestDiagnosticState()
        let run = UUID(), firstToken = UUID(), genericToken = UUID()
        owner.begin(run)
        owner.admit(.init(model: .project("gladia/solaria-1-streaming")), run: run)
        let snapshot = owner.freezeFailure(.init(), run: run)
        owner.publish(snapshot, token: firstToken)
        owner.publish(nil, token: genericToken)
        for token in [firstToken, genericToken, UUID()] {
            XCTAssertNil(try object(owner.snapshot(for: token))["context"])
        }
        owner.publish(nil, token: nil)
        XCTAssertNil(try object(owner.snapshot(for: genericToken))["context"])
    }

    func testCancelledStartupDiscardsOnlyItsOwnedFailureAndFreshStartCannotReadIt() throws {
        var owner = IOSRequestDiagnosticState()
        let run = UUID(), replacement = UUID()
        owner.begin(run)
        owner.admit(.init(model: .project("gladia/solaria-1-streaming")), run: run)
        XCTAssertNotNil(owner.freezeFailure(.init(), run: run))
        owner.discardFailure(run)
        XCTAssertNil(try object(owner.failedStartSnapshot(for: run))["context"])
        owner.retire(run)
        owner.begin(replacement)
        owner.admit(.init(model: .project("gladia/solaria-1-streaming")), run: replacement)
        XCTAssertNotNil(owner.freezeFailure(.init(), run: replacement))
        owner.discardFailure(run)
        XCTAssertNotNil(try object(owner.failedStartSnapshot(for: replacement))["context"])
        XCTAssertNil(try object(owner.failedStartSnapshot(for: run))["context"])
    }

    func testTypedWatchdogFailureRemainsFrozenAcrossTeardownWithoutRawErrorInput() throws {
        var owner = IOSRequestDiagnosticState()
        let run = UUID(), token = UUID()
        owner.begin(run)
        let snapshot = try XCTUnwrap(owner.freezeFailure(
            .init(stage: .finalization, code: .timeout, domain: .application), run: run
        ))
        owner.publish(snapshot, token: token)
        owner.retire(run)
        let failure = try XCTUnwrap((try object(owner.snapshot(for: token))["failures"] as? [[String: Any]])?.first)
        XCTAssertEqual(failure["stage"] as? String, "finalization")
        XCTAssertEqual(failure["code"] as? String, "timeout")
        XCTAssertEqual(failure["domain"] as? String, "application")
    }

    private func object(_ snapshot: IOSIssueReportSnapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.full.jsonData) as? [String: Any])
    }

    private func model(_ value: Any?) -> String? {
        ((value as? [String: Any])?["model"] as? [String: Any])?["identifier"] as? String
    }
}
#endif
