import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import XCTest
@testable import SpeakSync

final class DesktopComparisonSyncRoundTests: DesktopCloudSyncTestCase {
    func testCanonicalMetadataOnlyRoundTripRelaunchJudgingAndIndependentHistoryCursor() async throws {
        let transport = RecordingServerTransport(server: server)
        let fixture = try await comparisonFixture(transport: transport)
        let round = comparisonRound()
        try await fixture.store.upsert(round)
        let samples = fixture.store.directory.appendingPathComponent("Samples")
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        try Data("PRIVATE_SYNTHETIC_AUDIO".utf8).write(to: samples.appendingPathComponent(round.id.uuidString + ".wav"))
        try vault.writeCredential("PRIVATE_SYNTHETIC_PROVIDER_KEY", name: "synthetic-provider")
        let report = await fixture.service.sync()
        XCTAssertNil(report.error)
        let state = await fixture.state.current
        XCTAssertNotNil(state.comparisonCursor)
        XCTAssertNil(state.historyCursor)
        XCTAssertEqual(state.comparisonAcknowledgements?[round.id], round.updatedAt)
        let body = await transport.sent.map(\.body).joined()
        XCTAssertFalse(body.contains("PRIVATE_SYNTHETIC_AUDIO"))
        XCTAssertFalse(body.contains("PRIVATE_SYNTHETIC_PROVIDER_KEY"))
        XCTAssertFalse(body.contains(fixture.store.directory.path))
        let other = try DesktopComparisonStore(directory: directory.appendingPathComponent("OtherComparisons"))
        await fixture.service.installComparisonStore(other)
        try await fixture.state.update { $0.comparisonCursor = nil }
        let fetched = await fixture.service.sync()
        XCTAssertNil(fetched.error)
        let rounds = await other.rounds()
        XCTAssertEqual(rounds, [round])
        try await other.judge(id: round.id, ranksInBlindOrder: [2, 1])
        let judged = await fixture.service.sync()
        XCTAssertNil(judged.error)
        let relaunched = try DesktopComparisonStore(directory: other.directory)
        let saved = await relaunched.rounds()
        XCTAssertTrue(try XCTUnwrap(saved.first).isJudged)
        XCTAssertGreaterThan(try XCTUnwrap(saved.first).updatedAt, round.updatedAt)
        XCTAssertTrue(ModelComparisonExport.markdown(rounds: saved).contains("Scoreboard"))
    }

    func testOriginalAccountTombstoneNeverTransfersOrResurrects() async throws {
        let fixture = try await comparisonFixture()
        let round = comparisonRound()
        try await fixture.store.upsert(round)
        let initial = await fixture.service.sync()
        XCTAssertNil(initial.error)
        try await fixture.store.remove(id: round.id, at: fixtureDate(50))
        try await fixture.service.signOut()
        server.switchUser(to: "_synthetic-user-b")
        try await fixture.service.completeSignIn(webAuthToken: server.completeSignIn())
        let switched = await fixture.service.sync()
        XCTAssertNil(switched.error)
        let name = SyncSchema.ComparisonRound.recordName(for: round.id)
        XCTAssertNil(server.recordFields(zone: syncZone, recordName: name))
        let state = await fixture.state.current
        XCTAssertEqual(state.comparisonOwners?[round.id], "_synthetic-user-a")
        try await fixture.service.signOut()
        server.switchUser(to: "_synthetic-user-a")
        try await fixture.service.completeSignIn(webAuthToken: server.completeSignIn())
        let returned = await fixture.service.sync()
        XCTAssertNil(returned.error)
        let rounds = await fixture.store.rounds()
        XCTAssertTrue(rounds.isEmpty)
        XCTAssertEqual(
            server.recordFields(zone: syncZone, recordName: name)?["originPlatform"]?.value as? String,
            SyncSchema.ComparisonRound.tombstoneOriginPlatform
        )
    }

    func testExecutingRoundsAreNotUploadedOrRemotelyDeletedAndReleaseWithoutReplay() async throws {
        let fixture = try await comparisonFixture()
        let round = comparisonRound()
        try await fixture.store.upsert(round, isExecuting: true)
        let first = await fixture.service.sync()
        XCTAssertNil(first.error)
        let name = SyncSchema.ComparisonRound.recordName(for: round.id)
        XCTAssertNil(server.recordFields(zone: syncZone, recordName: name))
        try seedComparison(ModelComparisonRevision(deleting: round.id, at: fixtureDate(30)))
        let rejected = await fixture.service.sync()
        XCTAssertNotNil(rejected.error)
        let retained = await fixture.store.rounds()
        XCTAssertEqual(retained, [round])
        let relaunched = try DesktopComparisonStore(directory: fixture.store.directory)
        let recovered = await relaunched.revisions()
        XCTAssertEqual(recovered, [ModelComparisonRevision(round: round)])
        await fixture.store.endExecution(ids: [round.id])
        let applied = await fixture.service.sync()
        XCTAssertNil(applied.error)
        let remaining = await fixture.store.rounds()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUnownedLocalDeletionDoesNotCreateCloudRecordWhenConsentLaterEnabled() async throws {
        let fixture = try await comparisonFixture()
        let round = comparisonRound()
        try await fixture.service.setComparisonEnabled(false)
        try await fixture.store.upsert(round)
        try await fixture.store.remove(id: round.id, at: fixtureDate(50))
        try await fixture.service.setComparisonEnabled(true)
        let report = await fixture.service.sync()
        XCTAssertNil(report.error)
        let name = SyncSchema.ComparisonRound.recordName(for: round.id)
        XCTAssertNil(server.recordFields(zone: syncZone, recordName: name))
    }
}
