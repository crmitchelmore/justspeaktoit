import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopSync
import XCTest
@testable import SpeakSync

final class DesktopComparisonSyncPassTests: DesktopCloudSyncTestCase {
    func testHeldFetchAfterConsentOffCannotApplyAcknowledgeOrAdvanceCursor() async throws {
        try seedComparison(ModelComparisonRevision(round: comparisonRound()))
        let transport = RecordingServerTransport(server: server)
        let fixture = try await comparisonFixture(transport: transport)
        await transport.hold("private/changes/zone")
        let task = Task { await fixture.service.sync() }
        try await eventually { await transport.heldCount == 1 }
        try await fixture.service.setComparisonEnabled(false)
        let requests = await transport.sent.count
        await transport.releaseHeld()
        _ = await task.value
        await assertNoComparisonApplied(fixture)
        let finalRequests = await transport.sent.count
        XCTAssertEqual(finalRequests, requests)
    }

    func testHeldFetchAfterAccountSwitchCannotApplyOrRebindCursor() async throws {
        try seedComparison(ModelComparisonRevision(round: comparisonRound()))
        let transport = RecordingServerTransport(server: server)
        let fixture = try await comparisonFixture(transport: transport)
        await transport.hold("private/changes/zone")
        let task = Task { await fixture.service.sync() }
        try await eventually { await transport.heldCount == 1 }
        let logout = Task { try await fixture.service.signOut() }
        let currentClient = await fixture.service.client
        let client = try XCTUnwrap(currentClient)
        try await eventually { await client.waitingRequestCount > 0 }
        let requests = await transport.sent.count
        await transport.releaseHeld()
        try await logout.value
        server.switchUser(to: "_synthetic-user-b")
        try await fixture.service.completeSignIn(webAuthToken: server.completeSignIn())
        _ = await task.value
        await assertNoComparisonApplied(fixture)
        let finalRequests = await transport.sent.count
        XCTAssertEqual(finalRequests, requests)
        let state = await fixture.state.current
        XCTAssertEqual(state.boundAccount, "_synthetic-user-a")
        let next = await fixture.service.sync()
        XCTAssertNil(next.error)
        let rebound = await fixture.state.current
        XCTAssertEqual(rebound.boundAccount, "_synthetic-user-b")
    }

    func testHeldFetchAfterCancellationCannotApplyOrAdvanceCursor() async throws {
        try seedComparison(ModelComparisonRevision(round: comparisonRound()))
        let transport = RecordingServerTransport(server: server)
        let fixture = try await comparisonFixture(transport: transport)
        await transport.hold("private/changes/zone")
        let task = Task { await fixture.service.sync() }
        try await eventually { await transport.heldCount == 1 }
        task.cancel()
        await transport.releaseHeld()
        _ = await task.value
        await assertNoComparisonApplied(fixture)
    }

    func testConsentOffDuringLookupPreventsSubsequentUploadRequest() async throws {
        let transport = RecordingServerTransport(server: server)
        let fixture = try await comparisonFixture(transport: transport)
        let round = comparisonRound()
        try await fixture.store.upsert(round)
        await transport.hold("private/records/lookup")
        let task = Task { await fixture.service.sync() }
        try await eventually { await transport.heldCount == 1 }
        let before = await fixture.state.current
        XCTAssertEqual(before.comparisonOwners?[round.id], "_synthetic-user-a", "Ownership precedes upload.")
        try await fixture.service.setComparisonEnabled(false)
        let requests = await transport.sent.count
        await transport.releaseHeld()
        _ = await task.value
        let sent = await transport.sent
        XCTAssertEqual(sent.count, requests)
        XCTAssertFalse(sent.contains {
            $0.operation == "private/records/modify" && $0.body.contains(round.id.uuidString)
        })
        let state = await fixture.state.current
        XCTAssertNil(state.comparisonAcknowledgements?[round.id])
    }

    func testLateUploadAcknowledgementDoesNotClearNewerLocalRevision() async throws {
        let transport = RecordingServerTransport(server: server)
        let fixture = try await comparisonFixture(transport: transport)
        var round = comparisonRound()
        try await fixture.store.upsert(round)
        await transport.hold("private/records/modify")
        let task = Task { await fixture.service.sync() }
        try await eventually { await transport.heldCount == 1 }
        round.updatedAt = fixtureDate(20)
        round.entries[0].transcript = "Newer synthetic comparison"
        try await fixture.store.upsert(round)
        await transport.releaseHeld()
        _ = await task.value
        let pending = await fixture.store.pendingRevisions()
        XCTAssertEqual(pending, [ModelComparisonRevision(round: round)])
        let state = await fixture.state.current
        XCTAssertNotEqual(state.comparisonAcknowledgements?[round.id], round.updatedAt)
        let next = await fixture.service.sync()
        XCTAssertNil(next.error)
        let updated = await fixture.state.current
        XCTAssertEqual(updated.comparisonAcknowledgements?[round.id], round.updatedAt)
    }

    func testRemotePersistenceFailureKeepsComparisonCursorBeforePage() async throws {
        try seedComparison(ModelComparisonRevision(round: comparisonRound()))
        let fixture = try await comparisonFixture { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let report = await fixture.service.sync()
        XCTAssertNotNil(report.error)
        await assertNoComparisonApplied(fixture)
    }

    func testConsentOffAfterSubmittedUploadRefusesLateAcknowledgement() async throws {
        let transport = RecordingServerTransport(server: server)
        let fixture = try await comparisonFixture(transport: transport)
        let round = comparisonRound()
        try await fixture.store.upsert(round)
        await transport.hold("private/records/modify")
        let task = Task { await fixture.service.sync() }
        try await eventually { await transport.heldCount == 1 }
        let before = await fixture.state.current
        try await fixture.service.setComparisonEnabled(false)
        await transport.releaseHeld()
        _ = await task.value
        let after = await fixture.state.current
        XCTAssertNil(after.comparisonAcknowledgements?[round.id])
        XCTAssertEqual(after.comparisonCursor, before.comparisonCursor)
        let pending = await fixture.store.pendingRevisions()
        XCTAssertEqual(pending, [ModelComparisonRevision(round: round)])
    }

    func testConsentOffThenOnDoesNotReviveHeldResponseFromPreviousChoice() async throws {
        try seedComparison(ModelComparisonRevision(round: comparisonRound()))
        let transport = RecordingServerTransport(server: server)
        let fixture = try await comparisonFixture(transport: transport)
        await transport.hold("private/changes/zone")
        let task = Task { await fixture.service.sync() }
        try await eventually { await transport.heldCount == 1 }
        try await fixture.service.setComparisonEnabled(false)
        try await fixture.service.setComparisonEnabled(true)
        await transport.releaseHeld()
        let stale = await task.value
        XCTAssertNotNil(stale.error)
        await assertNoComparisonApplied(fixture)
        let next = await fixture.service.sync()
        XCTAssertNil(next.error)
        let rounds = await fixture.store.rounds()
        XCTAssertEqual(rounds.count, 1)
    }

    func testFailedConsentOffWriteStillStopsHeldPassAndReportsNondurableChoice() async throws {
        try seedComparison(ModelComparisonRevision(round: comparisonRound()))
        let transport = RecordingServerTransport(server: server)
        let fixture = try await comparisonFixture(transport: transport)
        await transport.hold("private/changes/zone")
        let task = Task { await fixture.service.sync() }
        try await eventually { await transport.heldCount == 1 }
        let stateFile = await fixture.state.url
        try FileManager.default.removeItem(at: stateFile)
        try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
        do {
            try await fixture.service.setComparisonEnabled(false)
            XCTFail("Expected an explicit persistence error.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disabled for this run"))
        }
        await transport.releaseHeld()
        _ = await task.value
        let state = await fixture.state.current
        XCTAssertFalse(state.enabledFeatures.contains(.comparisonRounds))
        await assertNoComparisonApplied(fixture)
    }
}
