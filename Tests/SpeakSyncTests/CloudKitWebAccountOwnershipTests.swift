import Foundation
import XCTest

@testable import SpeakSync

/// Reading, resetting and rebinding the account is one step that a sign-in or
/// sign-out can neither interrupt nor follow with stale work.
final class CloudKitWebAccountOwnershipTests: XCTestCase {
    private enum HoldPoint {
        case read
        case clear
        case bind
    }

    func testASignInWaitsWhileTheBoundAccountIsRead() async throws {
        try await assertRebindingFinishesBeforeASignIn(holding: .read)
    }

    func testASignInWaitsWhileCursorsAreCleared() async throws {
        try await assertRebindingFinishesBeforeASignIn(holding: .clear)
    }

    func testASignInWaitsWhileTheNewAccountIsBound() async throws {
        try await assertRebindingFinishesBeforeASignIn(holding: .bind)
    }

    func testAnEarlierValidationCannotEraseACursorSavedAfterALaterOne() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.setFallback(CloudKitWebFixture.response(["users": [["userRecordName": "_synthetic-a"]]]))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-account-a"), transport: transport)
        let accounts = HeldAccountStore(bound: "_synthetic-previous")
        let cursor = MemoryCursorStore(token: Data("cursor-previous".utf8))
        await cursor.holdNextClear()

        let first = Task { try await Self.validate(client, accounts, cursor) }
        try await eventually { await cursor.isHoldingClear }
        // A second validation, then the pass it admitted saving its cursor.
        let second = Task {
            let binding = try await Self.validate(client, accounts, cursor)
            try await cursor.saveChangeToken(Data("cursor-a".utf8))
            return binding
        }
        try await eventually {
            let saved = await cursor.saveCount == 1
            let queued = await client.waitingRequestCount == 1
            return saved || queued
        }
        await cursor.releaseClear()
        let firstBinding = try await first.value
        let secondBinding = try await second.value

        XCTAssertEqual(firstBinding, .changed)
        XCTAssertEqual(secondBinding, .unchanged, "the account was already rebound by the first validation")
        let token = try await cursor.loadChangeToken()
        XCTAssertEqual(token, Data("cursor-a".utf8), "a cursor saved after rebinding must not be reset again")
        let bound = await accounts.bound
        XCTAssertEqual(bound, "_synthetic-a")
    }

    /// Holds validation inside its account-bound step, signs another user in,
    /// then lets the step finish: the rebinding must complete, in the session
    /// it began in, before the sign-in takes effect.
    private func assertRebindingFinishesBeforeASignIn(
        holding point: HoldPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.setFallback(CloudKitWebFixture.response(["users": [["userRecordName": "_synthetic-a"]]]))
        let client = try makeTestClient(store: HeldTokenStore(token: "synthetic-account-a"), transport: transport)
        let log = EventLog()
        let accounts = HeldAccountStore(bound: "_synthetic-previous", log: log)
        let cursor = MemoryCursorStore(token: Data("cursor-previous".utf8), log: log)
        await Self.hold(point, accounts, cursor)

        let validation = Task { try await Self.validate(client, accounts, cursor) }
        try await eventually { await Self.isHolding(point, accounts, cursor) }
        let signIn = Task {
            try await client.storeWebAuthToken("synthetic-account-b")
            await log.append("signed in")
        }
        try await eventually {
            let signedIn = await log.entries.contains("signed in")
            let queued = await client.waitingRequestCount == 1
            return signedIn || queued
        }
        await Self.release(point, accounts, cursor)
        let binding = try await validation.value
        try await signIn.value

        XCTAssertEqual(binding, .changed, file: file, line: line)
        let events = await log.entries
        XCTAssertEqual(
            events, ["cleared", "bound _synthetic-a", "signed in"],
            "the sign-in took effect partway through rebinding", file: file, line: line
        )
    }

    private static func hold(_ point: HoldPoint, _ accounts: HeldAccountStore, _ cursor: MemoryCursorStore) async {
        switch point {
        case .read: await accounts.holdReads()
        case .clear: await cursor.holdNextClear()
        case .bind: await accounts.holdNextBind()
        }
    }

    private static func isHolding(
        _ point: HoldPoint,
        _ accounts: HeldAccountStore,
        _ cursor: MemoryCursorStore
    ) async -> Bool {
        switch point {
        case .read: return await accounts.heldReadCount == 1
        case .clear: return await cursor.isHoldingClear
        case .bind: return await accounts.isHoldingBind
        }
    }

    private static func release(_ point: HoldPoint, _ accounts: HeldAccountStore, _ cursor: MemoryCursorStore) async {
        switch point {
        case .read: await accounts.releaseReads()
        case .clear: await cursor.releaseClear()
        case .bind: await accounts.releaseBind()
        }
    }

    private static func validate(
        _ client: CloudKitWebServicesClient,
        _ accounts: HeldAccountStore,
        _ cursor: MemoryCursorStore
    ) async throws -> CloudKitWebSyncAccountBinding {
        try await CloudKitWebSyncAccount.validate(client: client, store: accounts, accountBoundCursors: [cursor])
    }
}
