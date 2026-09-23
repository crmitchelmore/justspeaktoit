import Foundation
import XCTest

@testable import SpeakSync

final class CloudKitWebSyncAccountTests: XCTestCase {
    func testFirstUseBindsTheAccountAndLaterChecksLeaveCursorsAlone() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.setFallback(CloudKitWebFixture.response(["users": [["userRecordName": "_synthetic-a"]]]))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-session"), transport: transport)
        let accounts = HeldAccountStore(bound: nil)
        let cursor = MemoryCursorStore(token: nil)

        let first = try await Self.validate(client, accounts, cursor)
        try await cursor.saveChangeToken(Data("cursor-a".utf8))
        let second = try await Self.validate(client, accounts, cursor)

        XCTAssertEqual(first, .firstUse)
        XCTAssertEqual(second, .unchanged)
        let bound = await accounts.bound
        XCTAssertEqual(bound, "_synthetic-a")
        let token = try await cursor.loadChangeToken()
        XCTAssertEqual(token, Data("cursor-a".utf8))
    }

    func testAnotherUsersSignInClearsEveryAccountBoundCursorBeforeRebinding() async throws {
        let transport = ScriptedCloudKitTransport()
        // The documented `users` array and a bare identity are both read.
        await transport.setFallback(CloudKitWebFixture.response(["userRecordName": "_synthetic-b"]))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-session"), transport: transport)
        let accounts = HeldAccountStore(bound: "_synthetic-a")
        let history = MemoryCursorStore(token: Data("history-a".utf8))
        let comparison = MemoryCursorStore(token: Data("comparison-a".utf8))

        let binding = try await CloudKitWebSyncAccount.validate(
            client: client,
            store: accounts,
            accountBoundCursors: [history, comparison]
        )

        XCTAssertEqual(binding, .changed)
        let bound = await accounts.bound
        XCTAssertEqual(bound, "_synthetic-b")
        let historyToken = try await history.loadChangeToken()
        let comparisonToken = try await comparison.loadChangeToken()
        XCTAssertNil(historyToken)
        XCTAssertNil(comparisonToken)
    }

    func testAnIdentityObservedBeforeASignInIsNeverBound() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.response(["users": [["userRecordName": "_synthetic-a"]]]))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-account-a"), transport: transport)
        let accounts = HeldAccountStore(bound: nil)
        await accounts.holdReads()
        let cursor = MemoryCursorStore(token: Data("cursor".utf8))

        let validation = Task { try await Self.validate(client, accounts, cursor) }
        try await eventually { await accounts.heldReadCount == 1 }
        try await client.storeWebAuthToken("synthetic-account-b")
        await accounts.releaseReads()

        do {
            _ = try await validation.value
            XCTFail("An identity from the previous session must not be bound")
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesError, .sessionChanged)
        }
        let bound = await accounts.bound
        XCTAssertNil(bound)
        let token = try await cursor.loadChangeToken()
        XCTAssertEqual(token, Data("cursor".utf8))
    }

    func testZoneCreationNeedsConsentAndTreatsAnExistingZoneAsSuccess() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.response(["zones": [[
            "zoneID": ["zoneName": SyncSchema.zoneName],
            "serverErrorCode": "EXISTS",
            "reason": "synthetic EXISTS"
        ]]]))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-session"), transport: transport)

        do {
            try await CloudKitWebSyncAccount.ensureSyncZone(for: .history, client: client, consent: .none)
            XCTFail("Zone creation must wait for consent")
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesError, .consentRequired(.history))
        }
        let noRequests = await transport.requests.isEmpty
        XCTAssertTrue(noRequests)

        let consent = CloudKitWebSyncConsent(enabledFeatures: [.history])
        try await CloudKitWebSyncAccount.ensureSyncZone(for: .history, client: client, consent: consent)
        let request = await transport.requests.first
        XCTAssertEqual(request?.url.path.hasSuffix("/private/zones/modify"), true)
        let operation = (request?.jsonBody["operations"] as? [[String: Any]])?.first
        XCTAssertEqual(operation?["operationType"] as? String, "create")
    }

    private static func validate(
        _ client: CloudKitWebServicesClient,
        _ accounts: HeldAccountStore,
        _ cursor: MemoryCursorStore
    ) async throws -> CloudKitWebSyncAccountBinding {
        try await CloudKitWebSyncAccount.validate(client: client, store: accounts, accountBoundCursors: [cursor])
    }
}

/// Remembers the bound account; reads can be held to order a test schedule.
actor HeldAccountStore: CloudKitWebSyncAccountStore {
    private(set) var bound: String?
    private var holdsReads = false
    private var heldReads: [CheckedContinuation<Void, Never>] = []

    init(bound: String?) {
        self.bound = bound
    }

    var heldReadCount: Int { heldReads.count }

    func holdReads() {
        holdsReads = true
    }

    func releaseReads() {
        holdsReads = false
        let waiting = heldReads
        heldReads.removeAll()
        waiting.forEach { $0.resume() }
    }

    func boundAccountRecordName() async throws -> String? {
        if holdsReads {
            await withCheckedContinuation { heldReads.append($0) }
        }
        return bound
    }

    func bindAccount(recordName: String) async throws {
        bound = recordName
    }
}

/// An in-memory cursor, as a desktop host's durable store would behave.
actor MemoryCursorStore: SyncChangeTokenStore {
    private var token: Data?
    private(set) var saveCount = 0

    init(token: Data?) {
        self.token = token
    }

    func loadChangeToken() async throws -> Data? {
        token
    }

    func saveChangeToken(_ token: Data) async throws {
        self.token = token
        saveCount += 1
    }

    func clearChangeToken() async throws {
        token = nil
    }
}
