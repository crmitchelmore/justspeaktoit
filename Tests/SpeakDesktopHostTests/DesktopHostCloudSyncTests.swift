import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakDesktopSync
import SpeakSync
import SpeakTestSupport

// The iCloud sync flow Windows and Linux share, driven through the fake
// platform, the stateful fake CloudKit server and a scripted loopback
// listener: sign-in, History in both directions, sign-out, timeouts and
// shutdown, with no browser, socket, keyring or network.

/// Routes the shared client to the fake CloudKit server in process.
private struct FakeServerTransport: CloudKitWebServicesHTTPTransport {
    let server: FakeCloudKitWebServer

    func send(
        _ request: CloudKitWebServicesHTTPRequest,
        responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse {
        let response = server.handle(method: request.method, url: request.url, body: request.body)
        return CloudKitWebServicesHTTPResponse(
            statusCode: response.status, headers: response.headers, body: response.body
        )
    }
}

private final class MemoryVault: DesktopCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readCredential(_ name: String) throws -> String? { lock.withLock { values[name] } }
    func writeCredential(_ value: String, name: String) throws { lock.withLock { values[name] = value } }
    func deleteCredential(_ name: String) throws { lock.withLock { values[name] = nil } }
}

/// These tests never import keys, so no primitive is ever reached.
private struct UnusedCryptography: SyncEnvelopeCryptography {
    func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data {
        throw CloudKitKeySyncError.encryptionFailed
    }
    func sealAESGCM(_ plaintext: Data, key: Data) throws -> SealedEnvelopePayload {
        throw CloudKitKeySyncError.encryptionFailed
    }
    func openAESGCM(_ sealed: SealedEnvelopePayload, key: Data) throws -> Data {
        throw CloudKitKeySyncError.encryptionFailed
    }
    func randomBytes(count: Int) throws -> Data { throw CloudKitKeySyncError.randomGenerationFailed }
}

/// A loopback listener whose requests the test delivers.
private final class ScriptedListener: DesktopLoopbackListener, @unchecked Sendable {
    struct Request: DesktopLoopbackRequest {
        let target: String?
        let listener: ScriptedListener
        /// A GET from this user's browser, as Apple's redirect arrives.
        var head: DesktopLoopbackRequestHead? {
            target.map {
                DesktopLoopbackRequestHead(method: "GET", target: $0, fields: [.init(name: "Host", value: "127.0.0.1")])
            }
        }
        var peer: DesktopLoopbackPeer { .currentUser }
        func respond(_ bytes: Data) { listener.record(target, bytes) }
    }

    private let lock = NSLock()
    private var queued: [String] = []
    private var answered: [(target: String?, response: String)] = []
    private var isClosed = false

    var responses: [(target: String?, response: String)] { lock.withLock { answered } }
    var closed: Bool { lock.withLock { isClosed } }

    func deliver(_ target: String) { lock.withLock { queued.append(target) } }

    fileprivate func record(_ target: String?, _ bytes: Data) {
        lock.withLock { answered.append((target, String(bytes: bytes, encoding: .utf8) ?? "")) }
    }

    func nextRequest(within timeout: Duration) async throws -> Request? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let target = lock.withLock({ queued.isEmpty ? nil : queued.removeFirst() }) {
                return Request(target: target, listener: self)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func close() { lock.withLock { isClosed = true } }
}

/// What the host's native side was asked to do, in order.
private final class NativeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [DesktopCloudSyncStatus] = []
    private var steps: [String] = []
    private var listeners: [ScriptedListener] = []
    private var opened: [URL] = []
    /// Called with each new listener once its page opens, to play the browser.
    var browser: (@Sendable (ScriptedListener) -> Void)?

    var statuses: [DesktopCloudSyncStatus] { lock.withLock { shown } }
    var events: [String] { lock.withLock { steps } }
    var createdListeners: [ScriptedListener] { lock.withLock { listeners } }
    var pages: [URL] { lock.withLock { opened } }

    func native(origin: String) -> DesktopHostCloudSyncNative {
        DesktopHostCloudSyncNative(
            originPlatform: origin,
            settingsLocation: "under Test sync",
            present: { [self] status in lock.withLock { shown.append(status) } },
            listen: { [self] port in
                let listener = ScriptedListener()
                lock.withLock {
                    steps.append("listen \(port)")
                    listeners.append(listener)
                }
                return listener
            },
            openSignInPage: { [self] page in
                let listener = lock.withLock { () -> ScriptedListener? in
                    opened.append(page)
                    steps.append("open")
                    return listeners.last
                }
                if let listener, let browser = lock.withLock({ self.browser }) { browser(listener) }
            }
        )
    }

    func note(_ step: String) { lock.withLock { steps.append(step) } }
}

final class DesktopHostCloudSyncTests: XCTestCase {
    private let apiToken = "synthetic-api-token"
    private var directory: URL!
    private var server: FakeCloudKitWebServer!
    private var vault: MemoryVault!
    private var log: NativeLog!
    private var controller: DesktopHostController<FakePlatform>!
    private var sync: DesktopHostCloudSync<FakePlatform>?

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = FakeCloudKitWebServer(apiToken: apiToken, containerIdentifier: "iCloud.com.justspeaktoit")
        vault = MemoryVault()
        log = NativeLog()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        if let sync { await sync.drain(sync.stop()) }
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    private func makeSync(
        token: String? = "synthetic-api-token",
        origin: String = DesktopHistorySyncProjection.linuxOriginPlatform,
        signInWindow: Duration = .seconds(30)
    ) throws -> DesktopHostCloudSync<FakePlatform> {
        var timing = DesktopHostCloudSyncTiming()
        timing.signInWindow = signInWindow
        let made = try DesktopHostCloudSync<FakePlatform>(
            controller: controller,
            resolution: DesktopCloudSyncConfiguration.resolve(
                buildToken: token, buildEnvironment: "production", processEnvironment: [:], train: .stable
            ),
            transport: FakeServerTransport(server: server),
            vault: vault,
            cryptography: UnusedCryptography(),
            native: log.native(origin: origin),
            timing: timing
        )
        sync = made
        return made
    }

    private func seedMacHistory(id: UUID, raw: String) {
        let name = id.uuidString
        server.seedRecord(zone: SyncSchema.zoneName, recordName: name, recordType: "TranscriptionHistory", fields: [
            "entryID": (id.uuidString, "STRING"),
            "createdAt": (Int64(1_800_000_000_000), "TIMESTAMP"),
            "rawTranscription": (raw, "STRING"),
            "model": ("deepgram/nova-3", "STRING"),
            "duration": (4.0, "DOUBLE"),
            "wordCount": (3, "INT64"),
            "originPlatform": ("macos", "STRING"),
            "updatedAt": (Int64(1_800_000_100_000), "TIMESTAMP")
        ])
    }

    private func waitFor(_ description: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<1_000 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func signedIn() throws {
        try vault.writeCredential(server.completeSignIn(), name: DesktopCloudSyncCredential.webAuthToken)
    }

    func testSignInOpensApplesPageAndFinishesFromTheLoopbackCallback() async throws {
        let sync = try makeSync()
        let server = server!
        log.browser = { listener in
            listener.deliver("/favicon.ico")
            listener.deliver("/cloudkit-sign-in?ckWebAuthToken=\(server.completeSignIn())")
        }
        await sync.start(controller: controller)
        XCTAssertEqual(log.statuses.first?.isSignedIn, false)

        sync.handle(.signIn)
        try await waitFor("sign-in") { log.statuses.last?.isSignedIn == true }

        XCTAssertEqual(log.pages.map(\.absoluteString), [FakeCloudKitWebServer.signInURL])
        XCTAssertEqual(log.events, ["listen 47823", "open"])
        let listener = try XCTUnwrap(log.createdListeners.first)
        XCTAssertTrue(listener.closed, "the callback stops listening once sign-in finishes")
        XCTAssertEqual(listener.responses.count, 2)
        XCTAssertEqual(listener.responses.first?.target, "/favicon.ico")
        XCTAssertTrue(listener.responses.first?.response.hasPrefix("HTTP/1.1 404") == true)
        XCTAssertTrue(listener.responses.last?.target?.hasPrefix("/cloudkit-sign-in?ckWebAuthToken=") == true)
        XCTAssertTrue(listener.responses.last?.response.hasPrefix("HTTP/1.1 200") == true)
        XCTAssertNotNil(try vault.readCredential(DesktopCloudSyncCredential.webAuthToken))
        let statuses = FakeLog.shared.allStatuses
        XCTAssertTrue(statuses.contains("Finish signing in with your Apple ID in your browser."), "\(statuses)")
        XCTAssertTrue(statuses.contains("Signed in to iCloud. Choose what to sync under Test sync."), "\(statuses)")
    }

    func testHistoryComesInFromTheMacAndGoesOutAsThisPlatform() async throws {
        try signedIn()
        let macID = UUID()
        seedMacHistory(id: macID, raw: "from the mac")
        var local = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "take.wav", modelIdentifier: "openai/whisper-1"
        )
        local.result = TranscriptionResult(
            text: "from linux", segments: [], confidence: nil, duration: 2, modelIdentifier: "openai/whisper-1",
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        try await controller.store.save(local)
        let sync = try makeSync()
        await sync.start(controller: controller)

        sync.handle(.apply(history: true, keys: false, passphrase: ""))
        try await waitFor("the Mac transcript") { await self.controller.history[macID] != nil }
        try await waitFor("the upload") {
            self.server.recordFields(zone: SyncSchema.zoneName, recordName: local.id.uuidString) != nil
        }

        let received = await controller.history[macID]
        XCTAssertEqual(received?.originPlatform, "macos")
        XCTAssertEqual(received?.result?.text, "from the mac")
        let uploaded = server.recordFields(zone: SyncSchema.zoneName, recordName: local.id.uuidString)
        XCTAssertEqual(uploaded?["originPlatform"]?.value as? String, "linux")
        // The pass uploads before it hands the settings their state, so the
        // shown state is awaited rather than read straight after the upload.
        try await waitFor("the settings to show History sync on") { self.log.statuses.last?.historyEnabled == true }
    }

    func testTheSelectedTranscriptLeavesWhenTheMacDeletesIt() async throws {
        try signedIn()
        let macID = UUID()
        seedMacHistory(id: macID, raw: "soon deleted")
        let sync = try makeSync()
        await sync.start(controller: controller)
        sync.handle(.apply(history: true, keys: false, passphrase: ""))
        try await waitFor("the Mac transcript") { await self.controller.history[macID] != nil }
        await controller.selectHistory(macID.uuidString)

        server.seedDeletion(zone: SyncSchema.zoneName, recordName: macID.uuidString)
        sync.handle(.syncNow)
        try await waitFor("the removal") { await self.controller.history[macID] == nil }

        let selected = await controller.selectedHistoryID
        XCTAssertNil(selected)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains("The selected recording was deleted on another device."))
    }

    func testSigningOutKeepsHistoryAndNamesThisComputer() async throws {
        try signedIn()
        let macID = UUID()
        seedMacHistory(id: macID, raw: "kept")
        let sync = try makeSync()
        await sync.start(controller: controller)
        sync.handle(.apply(history: true, keys: false, passphrase: ""))
        try await waitFor("the Mac transcript") { await self.controller.history[macID] != nil }

        sync.handle(.signOut)
        try await waitFor("sign-out") { self.log.statuses.last?.isSignedIn == false }

        let kept = await controller.history[macID]
        XCTAssertNotNil(kept)
        XCTAssertNil(try vault.readCredential(DesktopCloudSyncCredential.webAuthToken))
        XCTAssertTrue(FakeLog.shared.allStatuses.contains(
            "Signed out of iCloud on this computer. History and saved keys stay on this computer."
        ), "\(FakeLog.shared.allStatuses)")
    }

    func testASecondSignInWaitsForTheFirstListenerToClose() async throws {
        let sync = try makeSync()
        await sync.start(controller: controller)

        sync.handle(.signIn)
        try await waitFor("the first page") { self.log.pages.count == 1 }
        let first = try XCTUnwrap(log.createdListeners.first)
        log.browser = { [log] _ in log?.note("first closed: \(first.closed)") }
        sync.handle(.signIn)
        try await waitFor("the second page") { self.log.pages.count == 2 }

        XCTAssertEqual(log.events, ["listen 47823", "open", "listen 47823", "open", "first closed: true"])
    }

    func testASignInTheBrowserNeverFinishesTimesOutAndStopsListening() async throws {
        let sync = try makeSync(signInWindow: .milliseconds(100))
        await sync.start(controller: controller)

        sync.handle(.signIn)
        try await waitFor("the timeout") {
            FakeLog.shared.allStatuses.contains { $0.hasPrefix("iCloud sign-in did not finish:") }
        }

        XCTAssertTrue(FakeLog.shared.allStatuses.contains(
            "iCloud sign-in did not finish: " + DesktopCloudSyncError.signInTimedOut.localizedDescription
        ))
        XCTAssertEqual(log.createdListeners.first?.closed, true)
        XCTAssertEqual(log.statuses.last?.isSignedIn, false)
    }

    func testABuildWithoutATokenSaysWhyAndSyncsNothing() async throws {
        let sync = try makeSync(token: nil)
        await sync.start(controller: controller)

        sync.handle(.syncNow)
        try await waitFor("the explanation") {
            FakeLog.shared.allStatuses.contains { $0.contains("not available in this build") }
        }

        XCTAssertNotNil(log.statuses.first?.unavailableReason)
        XCTAssertEqual(log.statuses.first?.summary, log.statuses.first?.unavailableReason)
        XCTAssertTrue(server.requestLog.isEmpty, "nothing reaches CloudKit without a token")
    }

    func testStoppingDetachesFromTheWindowAndRefusesNewWork() async throws {
        let sync = try makeSync()
        await sync.start(controller: controller)
        try await waitFor("the first pass") { !self.log.statuses.isEmpty }

        await sync.drain(sync.stop())
        let shown = log.statuses.count
        sync.handle(.syncNow)
        sync.handle(.signIn)
        sync.requestSync()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(log.statuses.count, shown, "nothing reaches the window once stopped")
        XCTAssertTrue(log.pages.isEmpty, "no browser sign-in starts after shutdown")
    }

    func testImportedKeysAreNamedByProvider() throws {
        let providers = DesktopHostModels.all.compactMap { DesktopHostModels.provider(for: $0.id) }
        let openAI = try XCTUnwrap(providers.first { $0.apiKeyIdentifier == "openai.apiKey" })
        XCTAssertEqual(
            DesktopHostCloudSync<FakePlatform>.describe(imported: ["openai.apiKey", "unknown.apiKey"]),
            "Imported API keys from your Mac: \(openAI.displayName), unknown.apiKey."
        )
        XCTAssertEqual(
            DesktopHostCloudSync<FakePlatform>.describe(imported: []), "No new API keys to import from your Mac."
        )
    }
}
