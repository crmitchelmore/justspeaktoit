import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakSync

/// Sends every request to the stateful fake CloudKit Web Services server.
struct FakeServerTransport: CloudKitWebServicesHTTPTransport {
    let server: FakeCloudKitWebServer

    func send(
        _ request: CloudKitWebServicesHTTPRequest,
        responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse {
        let response = server.handle(method: request.method, url: request.url, body: request.body)
        guard response.body.count <= responseLimit else {
            throw CloudKitWebServicesTransportError.responseTooLarge(limit: responseLimit)
        }
        return CloudKitWebServicesHTTPResponse(
            statusCode: response.status,
            headers: response.headers,
            body: response.body
        )
    }
}

/// Keeps the rotating web auth token in memory, as Credential Manager would.
actor MemoryWebAuthTokenStore: CloudKitWebAuthTokenStore {
    private(set) var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func loadWebAuthToken() async throws -> String? { token }
    func saveWebAuthToken(_ token: String) async throws { self.token = token }
    func clearWebAuthToken() async throws { token = nil }
}

/// Remembers the bound iCloud user in memory.
actor MemoryAccountStore: CloudKitWebSyncAccountStore {
    private(set) var bound: String?

    func boundAccountRecordName() async throws -> String? { bound }
    func bindAccount(recordName: String) async throws { bound = recordName }
}

/// A fixed instant `seconds` after the fixtures' base time.
func fixtureTime(_ seconds: Int) -> Date {
    Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(seconds))
}

/// Records written the way a Mac App Store build writes them, in wire form.
enum MacRecordFixture {
    static let zone = SyncSchema.zoneName

    static func seedHistory(
        _ server: FakeCloudKitWebServer,
        id: UUID,
        raw: String,
        processed: String? = nil,
        updatedAt: Date
    ) {
        var fields: [String: (value: Any, type: String)] = [
            "entryID": (id.uuidString, "STRING"),
            "createdAt": (CloudKitWebFixture.milliseconds(fixtureTime(0)), "TIMESTAMP"),
            "rawTranscription": (raw, "STRING"),
            "model": ("deepgram/nova-3", "STRING"),
            "duration": (3.5, "DOUBLE"),
            "wordCount": (2, "INT64"),
            "originPlatform": ("macos", "STRING"),
            "updatedAt": (CloudKitWebFixture.milliseconds(updatedAt), "TIMESTAMP")
        ]
        if let processed {
            fields["postProcessedText"] = (processed, "STRING")
        }
        server.seedRecord(
            zone: zone,
            recordName: id.uuidString,
            recordType: SyncSchema.History.recordType,
            fields: fields
        )
    }
}

final class FakeCloudKitServerSyncTests: XCTestCase {
    private var server: FakeCloudKitWebServer!
    private var tokens: MemoryWebAuthTokenStore!
    private var client: CloudKitWebServicesClient!

    override func setUp() async throws {
        server = FakeCloudKitWebServer(
            apiToken: CloudKitWebFixture.apiToken,
            containerIdentifier: CloudKitWebFixture.containerIdentifier
        )
        tokens = MemoryWebAuthTokenStore()
        client = CloudKitWebServicesClient(
            configuration: try CloudKitWebFixture.configuration(),
            tokenStore: tokens,
            transport: FakeServerTransport(server: server),
            sleep: { _ in }
        )
    }

    private func signIn() async throws {
        try await client.completeSignIn(
            callbackURL: try XCTUnwrap(callbackURL(token: server.completeSignIn()))
        )
    }

    private func callbackURL(token: String) -> URL? {
        var components = URLComponents(string: "http://127.0.0.1:47823/cloudkit-sign-in")
        components?.queryItems = [URLQueryItem(name: "ckWebAuthToken", value: token)]
        return components?.url
    }

    private func history(consent: CloudKitWebSyncConsent = CloudKitWebSyncConsent(enabledFeatures: [.history]))
        throws -> CloudKitWebHistorySyncTransport {
        try CloudKitWebHistorySyncTransport(client: client, consent: consent)
    }

    // MARK: - Sign-in

    func testSigningInStartsFromTheRedirectAndRotatesTheTokenOnEveryResponse() async throws {
        do {
            _ = try await client.currentUserRecordName()
            XCTFail("An unsigned request must ask for sign-in")
        } catch CloudKitWebServicesError.authenticationRequired(let redirect) {
            XCTAssertEqual(redirect?.absoluteString, FakeCloudKitWebServer.signInURL)
        }

        try await signIn()
        let first = await tokens.token
        let firstCaller = try await client.currentUserRecordName()
        XCTAssertEqual(firstCaller, "_synthetic-user-a")
        let second = await tokens.token
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second, "Each response replaces the single-use token")
        let secondCaller = try await client.currentUserRecordName()
        XCTAssertEqual(secondCaller, "_synthetic-user-a")
    }

    func testAnExpiredSessionAsksForSignInAgainAndForgetsTheToken() async throws {
        try await signIn()
        server.expireSessions()
        do {
            _ = try await client.currentUserRecordName()
            XCTFail("An expired session must fail")
        } catch CloudKitWebServicesError.authenticationRequired(let redirect) {
            XCTAssertNotNil(redirect)
        }
        let stored = await tokens.token
        XCTAssertNil(stored)
    }

    // MARK: - History

    func testWindowsReceivesMacHistoryAndUploadsItsOwnInTheMacFormat() async throws {
        try await signIn()
        let macID = UUID()
        MacRecordFixture.seedHistory(
            server, id: macID, raw: "from the mac", processed: "From the Mac.",
            updatedAt: fixtureTime(100)
        )
        let windowsEntry = SyncWireFixture.entry(raw: "from windows", processed: "From Windows.")
        let store = FakeHistoryStore(entries: [windowsEntry])
        let accounts = MemoryAccountStore()
        let cursor = OrderedCursorStore(token: nil)

        let binding = try await CloudKitWebSyncAccount.validate(
            client: client, store: accounts, accountBoundCursors: [cursor]
        )
        XCTAssertEqual(binding, .firstUse)
        try await CloudKitWebSyncAccount.ensureSyncZone(
            for: .history, client: client, consent: CloudKitWebSyncConsent(enabledFeatures: [.history])
        )
        let host = HistoryHost(transport: try history(), tokens: cursor)
        await host.sync(store: store)

        let failure = await host.errorDescription
        XCTAssertNil(failure)
        let received = await store.received
        let mac = try XCTUnwrap(received.first { $0.id == macID })
        XCTAssertEqual(mac.rawTranscription, "from the mac")
        XCTAssertEqual(mac.postProcessedText, "From the Mac.")
        XCTAssertEqual(mac.originPlatform, "macos")
        XCTAssertEqual(mac.wordCount, 2)
        XCTAssertEqual(mac.duration, 3.5)

        let fields = try XCTUnwrap(
            server.recordFields(zone: MacRecordFixture.zone, recordName: windowsEntry.id.uuidString)
        )
        XCTAssertEqual(server.recordType(zone: MacRecordFixture.zone, recordName: windowsEntry.id.uuidString),
                       "TranscriptionHistory")
        XCTAssertEqual(Set(fields.keys), [
            "entryID", "createdAt", "rawTranscription", "postProcessedText", "model",
            "duration", "wordCount", "originPlatform", "updatedAt"
        ])
        XCTAssertEqual(fields["entryID"]?.type, "STRING")
        XCTAssertEqual(fields["createdAt"]?.type, "TIMESTAMP")
        XCTAssertEqual(fields["duration"]?.type, "DOUBLE")
        XCTAssertEqual(fields["wordCount"]?.type, "INT64")
        XCTAssertEqual(fields["updatedAt"]?.type, "TIMESTAMP")
        XCTAssertEqual(fields["originPlatform"]?.value as? String, "windows")
        let acknowledged = await store.acknowledgedIDs
        XCTAssertEqual(acknowledged, [macID, windowsEntry.id])
        let saves = await cursor.saves
        XCTAssertEqual(saves.count, 1)
    }

    func testLaterMacEditsAndDeletionsArriveThroughTheSavedCursor() async throws {
        try await signIn()
        let edited = UUID()
        let deleted = UUID()
        MacRecordFixture.seedHistory(server, id: edited, raw: "first", updatedAt: fixtureTime(10))
        MacRecordFixture.seedHistory(server, id: deleted, raw: "gone soon", updatedAt: fixtureTime(10))
        let store = FakeHistoryStore(entries: [])
        let cursor = OrderedCursorStore(token: nil)
        let host = HistoryHost(transport: try history(), tokens: cursor)
        await host.sync(store: store)

        MacRecordFixture.seedHistory(server, id: edited, raw: "second", updatedAt: fixtureTime(20))
        server.seedDeletion(zone: MacRecordFixture.zone, recordName: deleted.uuidString)
        await host.sync(store: store)

        let failure = await host.errorDescription
        XCTAssertNil(failure)
        let received = await store.received.filter { $0.id == edited }.map(\.rawTranscription)
        XCTAssertEqual(received, ["first", "second"], "The second pass reads only what changed after the cursor")
        let deletions = await store.deletedIDs
        XCTAssertEqual(deletions, [deleted])
    }

    func testTheNewerCopyWinsInBothDirections() async throws {
        try await signIn()
        let remoteNewer = SyncWireFixture.entry(raw: "stale local", updatedAt: fixtureTime(0))
        let localNewer = SyncWireFixture.entry(raw: "fresh local", updatedAt: fixtureTime(900))
        MacRecordFixture.seedHistory(server, id: remoteNewer.id, raw: "newer on mac",
                                     updatedAt: fixtureTime(500))
        MacRecordFixture.seedHistory(server, id: localNewer.id, raw: "older on mac",
                                     updatedAt: fixtureTime(500))
        let transport = try history()

        let result = await transport.upload(entries: [remoteNewer, localNewer])

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.acknowledgedIDs, [remoteNewer.id, localNewer.id])
        XCTAssertEqual(result.remoteEntries.map(\.rawTranscription), ["newer on mac"])
        let kept = server.recordFields(zone: MacRecordFixture.zone, recordName: remoteNewer.id.uuidString)
        XCTAssertEqual(kept?["rawTranscription"]?.value as? String, "newer on mac")
        let replaced = server.recordFields(zone: MacRecordFixture.zone, recordName: localNewer.id.uuidString)
        XCTAssertEqual(replaced?["rawTranscription"]?.value as? String, "fresh local")
    }

    func testClearingAProcessedTranscriptRemovesTheFieldOnTheServer() async throws {
        try await signIn()
        let entry = SyncWireFixture.entry(raw: "raw only", processed: nil,
                                          updatedAt: fixtureTime(900))
        MacRecordFixture.seedHistory(server, id: entry.id, raw: "raw", processed: "Processed.",
                                     updatedAt: fixtureTime(100))

        let transport = try history()
        let result = await transport.upload(entries: [entry])

        XCTAssertTrue(result.failures.isEmpty)
        let fields = server.recordFields(zone: MacRecordFixture.zone, recordName: entry.id.uuidString)
        XCTAssertNil(fields?["postProcessedText"])
        XCTAssertEqual(fields?["rawTranscription"]?.value as? String, "raw only")
    }

    func testAManyPageFeedSavesTheCursorAsEachPageIsCommitted() async throws {
        try await signIn()
        server.setPageLimit(2)
        let ids = (0..<5).map { _ in UUID() }
        for id in ids {
            MacRecordFixture.seedHistory(server, id: id, raw: "page", updatedAt: fixtureTime(10))
        }
        let store = FakeHistoryStore(entries: [])
        let cursor = OrderedCursorStore(token: nil)
        let host = HistoryHost(transport: try history(), tokens: cursor)

        await host.sync(store: store)

        let received = await Set(store.received.map(\.id))
        XCTAssertEqual(received, Set(ids))
        let saves = await cursor.saves
        XCTAssertEqual(saves.count, 3, "Each page's cursor is saved once that page is committed")
        XCTAssertEqual(Set(saves).count, 3)
        let feeds = server.requestLog.filter { $0 == "private/changes/zone" }.count
        XCTAssertEqual(feeds, 3)

        // The last saved cursor is the end of the feed: nothing is read again.
        await host.sync(store: store)
        let replayed = await store.received.count
        XCTAssertEqual(replayed, ids.count)
    }

    func testDeletingAWindowsEntryLeavesATombstoneForTheMac() async throws {
        try await signIn()
        server.createZone(MacRecordFixture.zone)
        let entry = SyncWireFixture.entry()
        let uploaded = await (try history()).upload(entries: [entry])
        XCTAssertEqual(uploaded.acknowledgedIDs, [entry.id])
        XCTAssertNotNil(server.recordFields(zone: MacRecordFixture.zone, recordName: entry.id.uuidString))

        try await history().delete(entryID: entry.id)
        try await history().delete(entryID: entry.id)

        XCTAssertNil(server.recordFields(zone: MacRecordFixture.zone, recordName: entry.id.uuidString))
    }

    func testAnotherAppleIDClearsTheCursorBeforeSyncing() async throws {
        try await signIn()
        let accounts = MemoryAccountStore()
        let cursor = OrderedCursorStore(token: Data("seq-9".utf8))
        let first = try await CloudKitWebSyncAccount.validate(
            client: client, store: accounts, accountBoundCursors: [cursor]
        )
        XCTAssertEqual(first, .firstUse)

        server.switchUser(to: "_synthetic-user-b")
        try await signIn()
        let second = try await CloudKitWebSyncAccount.validate(
            client: client, store: accounts, accountBoundCursors: [cursor]
        )

        XCTAssertEqual(second, .changed)
        let token = try await cursor.loadChangeToken()
        XCTAssertNil(token)
        let bound = await accounts.bound
        XCTAssertEqual(bound, "_synthetic-user-b")
    }

    func testHistoryCannotSyncWithoutConsent() async throws {
        XCTAssertThrowsError(try history(consent: .none)) {
            XCTAssertEqual($0 as? CloudKitWebServicesError, .consentRequired(.history))
        }
    }
}
