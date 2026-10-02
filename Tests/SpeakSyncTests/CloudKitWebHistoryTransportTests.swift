import Foundation
import XCTest

@testable import SpeakSync

final class CloudKitWebHistoryTransportTests: XCTestCase {
    private let consent = CloudKitWebSyncConsent(enabledFeatures: [.history])

    func testFeedPagesMapLikeTheNativeTransport() async throws {
        let transport = ScriptedCloudKitTransport()
        let kept = SyncWireFixture.entry(raw: "kept")
        let removed = UUID()
        let unnamedDeletion = UUID()
        await transport.enqueue(SyncWireFixture.zoneChanges([
            try SyncWireFixture.historyJSON(kept),
            try SyncWireFixture.recordJSON(name: "secret-b3BlbmFp", type: "EncryptedSecret", assignments: []),
            SyncWireFixture.deletedJSON(name: "comparison-\(UUID().uuidString)", type: "ModelComparisonRound"),
            SyncWireFixture.deletedJSON(name: removed.uuidString, type: SyncSchema.History.recordType)
        ], syncToken: "token-1", moreComing: true))
        await transport.enqueue(SyncWireFixture.zoneChanges([
            SyncWireFixture.deletedJSON(name: unnamedDeletion.uuidString, type: nil),
            SyncWireFixture.deletedJSON(name: SyncSchema.EncryptedSecret.recordName(for: "openai.apiKey"), type: nil)
        ], syncToken: "token-2", moreComing: false))
        let history = try makeTransport(transport)

        let first = try await history.fetchChanges(after: nil)
        let second = try await history.fetchChanges(after: first.serverChangeTokenData)

        XCTAssertEqual(first.changes.map(\.id), [kept.id, removed])
        if case .changed(let entry) = first.changes[0] {
            assertSameEntry(entry, kept)
        } else {
            XCTFail("Expected a change")
        }
        XCTAssertEqual(first.serverChangeTokenData, Data("token-1".utf8))
        XCTAssertTrue(first.moreComing)
        XCTAssertEqual(second.changes.map(\.id), [unnamedDeletion])
        XCTAssertEqual(second.serverChangeTokenData, Data("token-2".utf8))
        XCTAssertFalse(second.moreComing)
        let zones = await transport.requests.map { ($0.jsonBody["zones"] as? [[String: Any]])?.first }
        let zoneNames = zones.map { ($0?["zoneID"] as? [String: Any])?["zoneName"] as? String }
        XCTAssertEqual(zoneNames, [SyncSchema.zoneName, SyncSchema.zoneName])
        XCTAssertNil(zones[0]?["syncToken"])
        XCTAssertEqual(zones[1]?["syncToken"] as? String, "token-1")
    }

    func testPagesWithRecordErrorsOrAMissingZoneAreNotConsumed() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(SyncWireFixture.zoneChanges(
            [CloudKitWebFixture.recordError("INTERNAL_ERROR", recordName: UUID().uuidString)],
            syncToken: "must-not-advance",
            moreComing: false
        ))
        await transport.enqueue(CloudKitWebFixture.response(["zones": [[
            "zoneID": ["zoneName": SyncSchema.zoneName], "serverErrorCode": "ZONE_NOT_FOUND", "reason": "synthetic"
        ]]]))
        let history = try makeTransport(transport)

        for expected in [CloudKitWebServerErrorCode.internalError, .zoneNotFound] {
            do {
                _ = try await history.fetchChanges(after: nil)
                XCTFail("Expected \(expected.rawValue)")
            } catch let CloudKitWebServicesError.server(error) {
                XCTAssertEqual(error.code, expected)
            }
        }
    }

    func testOversizedPagesAreRequestedAgainWithHalvedRecordLimits() async throws {
        let transport = ScriptedCloudKitTransport()
        let oversized = SyncWireFixture.zoneChanges(
            [try SyncWireFixture.historyJSON(SyncWireFixture.entry(raw: String(repeating: "x", count: 4_096)))],
            syncToken: "large",
            moreComing: false
        )
        await transport.enqueue(oversized)
        await transport.enqueue(oversized)
        await transport.enqueue(SyncWireFixture.zoneChanges([], syncToken: "small", moreComing: true))
        let store = HeldTokenStore(token: "synthetic")
        let client = try makeTestClient(store: store, transport: transport, responseLimit: 2_048)
        let history = try CloudKitWebHistorySyncTransport(client: client, consent: consent)

        let page = try await history.fetchChanges(after: nil)

        XCTAssertEqual(page.serverChangeTokenData, Data("small".utf8))
        let limits = await transport.requests.map {
            (($0.jsonBody["zones"] as? [[String: Any]])?.first?["resultsLimit"] as? Int) ?? 0
        }
        XCTAssertEqual(limits, [0, 100, 50])
    }

    func testUploadResolvesEveryEntryAgainstItsOwnRecord() async throws {
        let created = SyncWireFixture.entry(raw: "new")
        let serverWins = SyncWireFixture.entry(raw: "local", updatedAt: Date(timeIntervalSince1970: 1_800_000_010))
        let serverCopy = SyncWireFixture.entry(
            id: serverWins.id,
            raw: "server",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_020)
        )
        let localWins = SyncWireFixture.entry(raw: "local", updatedAt: Date(timeIntervalSince1970: 1_800_000_030))
        let staleServer = SyncWireFixture.entry(
            id: localWins.id,
            raw: "stale",
            processed: "stale processed",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        let lookupFails = SyncWireFixture.entry(raw: "lookup fails")
        let conflicts = SyncWireFixture.entry(raw: "conflicts")
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.records([
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: created.id.uuidString),
            try SyncWireFixture.historyJSON(serverCopy, tag: "tag-server"),
            try SyncWireFixture.historyJSON(staleServer, tag: "tag-stale"),
            CloudKitWebFixture.recordError("INTERNAL_ERROR", recordName: lookupFails.id.uuidString),
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: conflicts.id.uuidString)
        ]))
        await transport.enqueue(CloudKitWebFixture.records([
            ["recordName": created.id.uuidString, "recordChangeTag": "t1"],
            ["recordName": localWins.id.uuidString, "recordChangeTag": "t2"],
            CloudKitWebFixture.recordError("EXISTS", recordName: conflicts.id.uuidString)
        ]))
        let history = try makeTransport(transport)

        let result = await history.upload(entries: [created, serverWins, localWins, lookupFails, conflicts])

        XCTAssertEqual(result.acknowledgedIDs, [created.id, serverWins.id, localWins.id])
        XCTAssertEqual(result.remoteEntries.count, 1)
        assertSameEntry(result.remoteEntries.first, serverCopy)
        XCTAssertEqual(Set(result.failures.keys), [lookupFails.id, conflicts.id])
        let modify = await transport.requests.last?.jsonBody
        XCTAssertEqual(modify?["atomic"] as? Bool, false)
        XCTAssertEqual((modify?["desiredKeys"] as? [String])?.isEmpty, true)
        let operations = modify?["operations"] as? [[String: Any]] ?? []
        XCTAssertEqual(operations.map { $0["operationType"] as? String }, ["create", "update", "create"])
        let update = operations[1]["record"] as? [String: Any]
        XCTAssertEqual(update?["recordChangeTag"] as? String, "tag-stale")
        let fields = update?["fields"] as? [String: Any]
        let cleared = fields?["postProcessedText"] as? [String: Any]
        XCTAssertTrue(cleared?["value"] is NSNull, "the server's processed text is cleared explicitly")
    }

    func testFailedLookupRequestFailsTheWholeBatchWithoutWriting() async throws {
        let entries = [SyncWireFixture.entry(), SyncWireFixture.entry()]
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.serverError("BAD_REQUEST", status: 400))
        let history = try makeTransport(transport)

        let result = await history.upload(entries: entries)

        XCTAssertTrue(result.acknowledgedIDs.isEmpty)
        XCTAssertEqual(Set(result.failures.keys), Set(entries.map(\.id)))
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testAnEntryJSONCannotCarryFailsAlone() async throws {
        let valid = SyncWireFixture.entry()
        let invalid = SyncableHistoryEntry(
            id: UUID(), createdAt: valid.createdAt, rawTranscription: "nan", postProcessedText: nil,
            model: "m", duration: .nan, wordCount: 1, originPlatform: "windows", updatedAt: valid.updatedAt
        )
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.records([
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: valid.id.uuidString),
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: invalid.id.uuidString)
        ]))
        await transport.enqueue(CloudKitWebFixture.records([["recordName": valid.id.uuidString]]))
        let history = try makeTransport(transport)

        let result = await history.upload(entries: [valid, invalid])

        XCTAssertEqual(result.acknowledgedIDs, [valid.id])
        XCTAssertTrue(result.failures[invalid.id] is SyncError)
    }

    func testDeleteIsATaglessDeleteAndAnAbsentRecordIsAlreadyDeleted() async throws {
        let transport = ScriptedCloudKitTransport()
        let absent = UUID()
        let denied = UUID()
        await transport.enqueue(CloudKitWebFixture.records([
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: absent.uuidString)
        ]))
        await transport.enqueue(CloudKitWebFixture.records([
            CloudKitWebFixture.recordError("ACCESS_DENIED", recordName: denied.uuidString)
        ]))
        let history = try makeTransport(transport)

        try await history.delete(entryID: absent)
        do {
            try await history.delete(entryID: denied)
            XCTFail("Expected the per-record failure")
        } catch let CloudKitWebServicesError.server(error) {
            XCTAssertEqual(error.code, .accessDenied)
        }
        let firstRequest = await transport.requests.first
        let operation = (firstRequest?.jsonBody["operations"] as? [[String: Any]])?.first
        XCTAssertEqual(operation?["operationType"] as? String, "forceDelete")
        XCTAssertEqual((operation?["record"] as? [String: Any])?["recordName"] as? String, absent.uuidString)
    }

    func testTransportsExistOnlyWithTheirFeaturesConsent() throws {
        let client = try makeTestClient(store: HeldTokenStore(token: nil), transport: ScriptedCloudKitTransport())
        XCTAssertThrowsError(try CloudKitWebHistorySyncTransport(client: client, consent: .none)) {
            XCTAssertEqual($0 as? CloudKitWebServicesError, .consentRequired(.history))
        }
        XCTAssertThrowsError(try CloudKitWebComparisonSyncTransport(client: client, consent: consent)) {
            XCTAssertEqual($0 as? CloudKitWebServicesError, .consentRequired(.comparisonRounds))
        }
    }

    func testWritesBuiltFromOneSessionAreNeverSentInTheNext() async throws {
        let entry = SyncWireFixture.entry()
        let transport = ScriptedCloudKitTransport()
        await transport.holdRequests()
        await transport.enqueue(CloudKitWebFixture.records([
            CloudKitWebFixture.recordError("NOT_FOUND", recordName: entry.id.uuidString)
        ]))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-account-a"), transport: transport)
        let history = try CloudKitWebHistorySyncTransport(client: client, consent: consent)

        let upload = Task { await history.upload(entries: [entry]) }
        try await eventually { await transport.heldCount == 1 }
        let signIn = Task { try await client.storeWebAuthToken("synthetic-account-b") }
        try await eventually { await client.waitingRequestCount == 1 }
        await transport.releaseHeldRequests()
        try await signIn.value
        let result = await upload.value

        XCTAssertEqual(result.failures[entry.id] as? CloudKitWebServicesError, .sessionChanged)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "the create built from account A's lookup must not reach account B")
    }

    private func makeTransport(_ transport: ScriptedCloudKitTransport) throws -> CloudKitWebHistorySyncTransport {
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-session"), transport: transport)
        return try CloudKitWebHistorySyncTransport(client: client, consent: consent)
    }
}
