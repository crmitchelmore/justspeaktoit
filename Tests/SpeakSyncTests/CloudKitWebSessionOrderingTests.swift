import Foundation
import XCTest

@testable import SpeakSync

/// Ordering of the rotating web auth session: every token read and session
/// change passes one boundary, and no operation continues across a sign-in.
final class CloudKitWebSessionOrderingTests: XCTestCase {
    func testHeldInitialLoadCannotRestoreASessionThatSignOutCleared() async throws {
        let store = HeldTokenStore(token: "synthetic-session-a")
        await store.holdLoads()
        let transport = ScriptedCloudKitTransport()
        let client = try makeTestClient(store: store, transport: transport)

        let probe = Task { try await client.hasWebAuthToken() }
        try await eventually { await store.pendingLoadCount == 1 }
        let signedOut = Flag()
        let signOut = Task {
            try await client.signOut()
            await signedOut.set()
        }
        try await eventually {
            let finished = await signedOut.isSet
            let queued = await client.waitingRequestCount == 1
            return finished || queued
        }
        await store.releaseNewestLoad()
        _ = try await probe.value
        try await signOut.value

        let signedIn = try await client.hasWebAuthToken()
        XCTAssertFalse(signedIn, "a read that began before sign-out must not restore the cleared session")
        _ = try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["probe"])
        let requests = await transport.requests
        XCTAssertNil(requests.last?.webAuthToken)
        let loads = await store.loadCount
        XCTAssertEqual(loads, 1, "the persisted session is read once")
    }

    func testHeldInitialLoadCannotOverwriteATokenRotatedByALaterRequest() async throws {
        let store = HeldTokenStore(token: "synthetic-session-a1")
        await store.holdLoads()
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.records([]).rotating(to: "synthetic-session-a2"))
        let client = try makeTestClient(store: store, transport: transport)

        let probe = Task { try await client.hasWebAuthToken() }
        try await eventually { await store.pendingLoadCount == 1 }
        let request = Task { try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["first"]) }
        try await eventually {
            let secondRead = await store.pendingLoadCount == 2
            let queued = await client.waitingRequestCount == 1
            return secondRead || queued
        }
        // Deliver the later read first, so an earlier read would land last.
        await store.releaseNewestLoad()
        try await eventually { await transport.requests.count == 1 }
        _ = try await request.value
        await store.releaseNewestLoad()
        _ = try await probe.value
        _ = try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["second"])

        let tokens = await transport.requests.map(\.webAuthToken)
        XCTAssertEqual(tokens, ["synthetic-session-a1", "synthetic-session-a2"])
        let loads = await store.loadCount
        XCTAssertEqual(loads, 1, "a second initial read must not race the first")
    }

    func testHeldBackoffNeverReplaysAnOldSessionPayloadUnderANewSignIn() async throws {
        let store = HeldTokenStore(token: "synthetic-account-a")
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(
            CloudKitWebFixture.serverError("TRY_AGAIN_LATER", status: 503, rotatedToken: "synthetic-account-a2")
        )
        let sleeper = HeldSleeper()
        let client = try makeTestClient(store: store, transport: transport, sleeper: sleeper)
        let oldPayload = CloudKitWebRecordWrite.forceDelete(recordName: "old-session-record")

        let operation = Task {
            try await client.modifyRecords(zoneName: SyncSchema.zoneName, operations: [oldPayload])
        }
        try await eventually { await sleeper.waiterCount == 1 }
        // The backoff does not hold the gate: sign-out and a new sign-in finish now.
        try await client.signOut()
        try await client.storeWebAuthToken("synthetic-account-b")
        await sleeper.resumeAll()

        do {
            _ = try await operation.value
            XCTFail("an operation begun under account A must not complete under account B")
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesError, .sessionChanged)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.webAuthToken), ["synthetic-account-a"])
        XCTAssertFalse(requests.contains {
            $0.webAuthToken == "synthetic-account-b" && $0.bodyText.contains("old-session-record")
        })
        _ = try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["new-session"])
        let latest = await transport.requests.last
        XCTAssertEqual(latest?.webAuthToken, "synthetic-account-b")
    }

    func testHeldBackoffRetryKeepsTheSameSessionsRotatedToken() async throws {
        let store = HeldTokenStore(token: "synthetic-account-a")
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(
            CloudKitWebFixture.serverError("TRY_AGAIN_LATER", status: 503, rotatedToken: "synthetic-account-a2")
        )
        let sleeper = HeldSleeper()
        let client = try makeTestClient(store: store, transport: transport, sleeper: sleeper)

        let operation = Task {
            try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["same-session"])
        }
        try await eventually { await sleeper.waiterCount == 1 }
        await sleeper.resumeAll()
        _ = try await operation.value

        let tokens = await transport.requests.map(\.webAuthToken)
        XCTAssertEqual(tokens, ["synthetic-account-a", "synthetic-account-a2"])
        let saved = await store.saved
        XCTAssertEqual(saved, ["synthetic-account-a2"])
    }

    func testOperationsQueuedBehindARejectedSessionAreNotSentSignedOut() async throws {
        let store = HeldTokenStore(token: "synthetic-expired")
        let transport = ScriptedCloudKitTransport()
        await transport.holdRequests()
        await transport.enqueue(CloudKitWebFixture.serverError("AUTHENTICATION_REQUIRED", status: 421))
        let client = try makeTestClient(store: store, transport: transport)

        let first = Task { try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["first"]) }
        try await eventually { await transport.heldCount == 1 }
        let second = Task { try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["second"]) }
        try await eventually { await client.waitingRequestCount == 1 }
        await transport.releaseHeldRequests()

        await assertFailure(first, .authenticationRequired(redirectURL: nil))
        await assertFailure(second, .sessionChanged)
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
        let cleared = await store.clearCount
        XCTAssertEqual(cleared, 1)
    }

    func testSignInQueuedBehindAnInFlightRequestWinsOverItsRotation() async throws {
        let store = HeldTokenStore(token: "synthetic-account-a")
        let transport = ScriptedCloudKitTransport()
        await transport.holdRequests()
        await transport.enqueue(CloudKitWebFixture.records([]).rotating(to: "synthetic-account-a2"))
        let client = try makeTestClient(store: store, transport: transport)

        let request = Task { try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["in-flight"]) }
        try await eventually { await transport.heldCount == 1 }
        let signIn = Task { try await client.storeWebAuthToken("synthetic-account-b") }
        try await eventually { await client.waitingRequestCount == 1 }
        await transport.releaseHeldRequests()
        _ = try await request.value
        try await signIn.value

        let saved = await store.saved
        XCTAssertEqual(saved, ["synthetic-account-a2", "synthetic-account-b"])
        _ = try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["after-sign-in"])
        let latest = await transport.requests.last?.webAuthToken
        XCTAssertEqual(latest, "synthetic-account-b")
    }

    func testCancelledQueuedRequestDoesNotStrandTheGate() async throws {
        let store = HeldTokenStore(token: "synthetic-session")
        let transport = ScriptedCloudKitTransport()
        await transport.holdRequests()
        let client = try makeTestClient(store: store, transport: transport)

        let first = Task { try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["first"]) }
        try await eventually { await transport.heldCount == 1 }
        let second = Task { try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["second"]) }
        try await eventually { await client.waitingRequestCount == 1 }
        second.cancel()
        await assertCancelled(second)
        let waiting = await client.waitingRequestCount
        XCTAssertEqual(waiting, 0)

        await transport.releaseHeldRequests()
        _ = try await first.value
        _ = try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["third"])
        let bodies = await transport.requests.map(\.bodyText)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("first"))
        XCTAssertTrue(bodies[1].contains("third"))
    }

    func testCancelledRequestInFlightReleasesTheGateToTheNextOperation() async throws {
        let store = HeldTokenStore(token: "synthetic-session")
        let transport = ScriptedCloudKitTransport()
        await transport.holdRequests()
        let client = try makeTestClient(store: store, transport: transport)

        let first = Task { try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["first"]) }
        try await eventually { await transport.heldCount == 1 }
        let second = Task { try await client.lookupRecords(zoneName: SyncSchema.zoneName, recordNames: ["second"]) }
        try await eventually { await client.waitingRequestCount == 1 }
        first.cancel()
        await assertCancelled(first)

        try await eventually {
            let sent = await transport.requests.count == 2
            let held = await transport.heldCount == 1
            return sent && held
        }
        await transport.releaseHeldRequests()
        _ = try await second.value
        let waiting = await client.waitingRequestCount
        XCTAssertEqual(waiting, 0)
    }

    private func assertFailure<Success>(
        _ task: Task<Success, Error>,
        _ expected: CloudKitWebServicesError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesError, expected, file: file, line: line)
        }
    }

    private func assertCancelled<Success>(
        _ task: Task<Success, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
        }
    }
}

actor Flag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}

extension CloudKitWebServicesHTTPResponse {
    func rotating(to token: String) -> CloudKitWebServicesHTTPResponse {
        var headers = self.headers
        headers[CloudKitWebServicesClient.webAuthTokenHeader.lowercased()] = token
        return CloudKitWebServicesHTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }
}
