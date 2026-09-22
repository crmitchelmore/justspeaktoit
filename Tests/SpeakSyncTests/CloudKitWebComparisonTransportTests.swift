import Foundation
import SpeakCore
import XCTest

@testable import SpeakSync

final class CloudKitWebComparisonTransportTests: XCTestCase {
    private let consent = CloudKitWebSyncConsent(enabledFeatures: [.comparisonRounds])

    func testFeedReadsRevisionsTombstonesAndLegacyDeletionsOnly() async throws {
        let round = SyncWireFixture.round()
        let tombstone = ModelComparisonRevision(deleting: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000.125))
        let legacyDeletion = UUID()
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(SyncWireFixture.zoneChanges([
            try SyncWireFixture.comparisonJSON(ModelComparisonRevision(round: round)),
            try SyncWireFixture.comparisonJSON(tombstone),
            try SyncWireFixture.historyJSON(SyncWireFixture.entry()),
            SyncWireFixture.deletedJSON(name: SyncSchema.ComparisonRound.recordName(for: legacyDeletion), type: nil),
            SyncWireFixture.deletedJSON(name: UUID().uuidString, type: SyncSchema.History.recordType)
        ], syncToken: "comparison-token", moreComing: false))
        let comparisons = try makeTransport(transport)

        let page = try await comparisons.fetchChanges(after: nil)

        XCTAssertEqual(page.changes.count, 3)
        guard case .revision(let first) = page.changes[0], case .revision(let second) = page.changes[1],
              case .deleted(let deleted) = page.changes[2] else {
            return XCTFail("Unexpected changes")
        }
        XCTAssertEqual(first, ModelComparisonRevision(round: round))
        XCTAssertEqual(second, tombstone)
        XCTAssertEqual(deleted, legacyDeletion)
        XCTAssertEqual(page.serverChangeTokenData, Data("comparison-token".utf8))
    }

    func testAPageWithARoundThisBuildCannotReadIsNotConsumed() async throws {
        let revision = ModelComparisonRevision(round: SyncWireFixture.round())
        var newer = try SyncWireFixture.comparisonJSON(revision)
        var fields = newer["fields"] as? [String: Any] ?? [:]
        fields["schemaVersion"] = CloudKitWebFixture.field(ModelComparisonRound.schemaVersion + 1, "INT64")
        newer["fields"] = fields
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(SyncWireFixture.zoneChanges([newer], syncToken: "must-not-advance", moreComing: false))
        let comparisons = try makeTransport(transport)

        do {
            _ = try await comparisons.fetchChanges(after: nil)
            XCTFail("A newer schema must be replayed by a compatible build")
        } catch {
            XCTAssertTrue(error is SyncError)
        }
    }

    func testUploadAppliesTheNativeConflictRule() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let localNewer = ModelComparisonRevision(round: SyncWireFixture.round(updatedAt: base.addingTimeInterval(20)))
        let serverOlder = ModelComparisonRevision(round: withID(localNewer.id, updatedAt: base.addingTimeInterval(10)))
        let localOlder = ModelComparisonRevision(round: SyncWireFixture.round(updatedAt: base.addingTimeInterval(10)))
        let serverNewer = ModelComparisonRevision(round: withID(localOlder.id, updatedAt: base.addingTimeInterval(30)))
        let localAtTie = ModelComparisonRevision(round: SyncWireFixture.round(updatedAt: base.addingTimeInterval(40)))
        let serverTombstone = ModelComparisonRevision(deleting: localAtTie.id, at: base.addingTimeInterval(40))
        let absent = ModelComparisonRevision(round: SyncWireFixture.round())
        let unreadable = ModelComparisonRevision(round: SyncWireFixture.round())
        let absentName = SyncSchema.ComparisonRound.recordName(for: absent.id)
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.records([
            try SyncWireFixture.comparisonJSON(serverOlder, tag: "tag-older"),
            try SyncWireFixture.comparisonJSON(serverNewer),
            try SyncWireFixture.comparisonJSON(serverTombstone),
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: absentName),
            try SyncWireFixture.recordJSON(
                name: SyncSchema.ComparisonRound.recordName(for: unreadable.id),
                type: SyncSchema.ComparisonRound.recordType,
                assignments: [("schemaVersion", .int64(Int64(ModelComparisonRound.schemaVersion)))]
            )
        ]))
        await transport.enqueue(CloudKitWebFixture.records([
            ["recordName": SyncSchema.ComparisonRound.recordName(for: localNewer.id)],
            ["recordName": absentName]
        ]))
        let comparisons = try makeTransport(transport)

        let result = await comparisons.upload(revisions: [localNewer, localOlder, localAtTie, absent, unreadable])

        XCTAssertEqual(result.acknowledged, [localNewer, absent])
        XCTAssertEqual(result.remote, [serverNewer, serverTombstone])
        XCTAssertEqual(Set(result.failures.keys), [unreadable.id])
        let operations = await transport.requests.last?.jsonBody["operations"] as? [[String: Any]] ?? []
        XCTAssertEqual(operations.map { $0["operationType"] as? String }, ["update", "create"])
        XCTAssertEqual((operations[0]["record"] as? [String: Any])?["recordChangeTag"] as? String, "tag-older")
    }

    private func withID(_ id: UUID, updatedAt: Date) -> ModelComparisonRound {
        let template = SyncWireFixture.round(updatedAt: updatedAt)
        return ModelComparisonRound(
            id: id,
            createdAt: template.createdAt,
            updatedAt: updatedAt,
            inputMode: template.inputMode,
            sample: template.sample,
            language: template.language,
            originPlatform: template.originPlatform,
            entries: template.entries,
            blindOrder: template.blindOrder
        )
    }

    private func makeTransport(_ transport: ScriptedCloudKitTransport) throws -> CloudKitWebComparisonSyncTransport {
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-session"), transport: transport)
        return try CloudKitWebComparisonSyncTransport(client: client, consent: consent)
    }
}
