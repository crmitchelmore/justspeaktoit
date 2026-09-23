import Foundation
import XCTest

@testable import SpeakSync

/// The shared coordinator over the web transport, against synthetic CloudKit
/// responses. This is source-level interoperability evidence only: no request
/// here reaches iCloud.
final class CloudKitWebEndToEndTests: XCTestCase {
    func testAPassReconcilesTheFeedThenUploadsPendingEntries() async throws {
        let local = SyncWireFixture.entry(raw: "local only")
        let remote = SyncWireFixture.entry(raw: "from a Mac")
        let deletedElsewhere = SyncWireFixture.entry(raw: "deleted on a Mac")
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(
            SyncWireFixture.zoneChanges([try SyncWireFixture.historyJSON(remote)], syncToken: "t1", moreComing: true)
        )
        await transport.enqueue(SyncWireFixture.zoneChanges(
            [SyncWireFixture.deletedJSON(name: deletedElsewhere.id.uuidString, type: SyncSchema.History.recordType)],
            syncToken: "t2",
            moreComing: false
        ))
        await transport.enqueue(CloudKitWebFixture.records([
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: local.id.uuidString)
        ]))
        await transport.enqueue(CloudKitWebFixture.records([
            ["recordName": local.id.uuidString, "recordChangeTag": "t"]
        ]))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-session"), transport: transport)
        let web = try CloudKitWebHistorySyncTransport(
            client: client,
            consent: CloudKitWebSyncConsent(enabledFeatures: [.history])
        )
        let store = FakeHistoryStore(entries: [local, deletedElsewhere])
        let cursor = OrderedCursorStore(token: nil, loggingInto: store)
        let host = HistoryHost(transport: web, tokens: cursor)

        await host.sync(store: store)

        let error = await host.errorDescription
        XCTAssertNil(error)
        let lastSync = await host.lastSyncTime
        XCTAssertEqual(lastSync, Date(timeIntervalSince1970: 42))
        // The feed commits before its cursor advances; applying the upload's
        // acknowledgements commits again, exactly as the Apple engine does.
        let log = await store.log
        XCTAssertEqual(log, ["receive", "delete", "commit", "save-cursor", "commit"])
        let saves = await cursor.saves
        XCTAssertEqual(saves, [Data("t2".utf8)])
        let acknowledged = await store.acknowledgedIDs
        XCTAssertEqual(acknowledged, [local.id, remote.id])
        let operations = await transport.requests.map { request in
            request.url.pathComponents.suffix(2).joined(separator: "/")
        }
        XCTAssertEqual(operations, ["changes/zone", "changes/zone", "records/lookup", "records/modify"])
    }
}
