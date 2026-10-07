import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Glibc
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import SpeakLinuxPlatform
import SpeakSync
import SpeakTestSupport
import XCTest

/// Serves the stateful fake CloudKit server on a real loopback socket, so
/// requests go through URLSession (libcurl) exactly as they do against iCloud.
final class LoopbackCloudKitServer: @unchecked Sendable {
    let listener: LinuxLoopbackListener
    private var task: Task<Void, Never>?

    init(server: FakeCloudKitWebServer) throws {
        listener = try LinuxLoopbackListener()
        let listener = listener
        task = Task.detached {
            while !Task.isCancelled {
                guard let connection = try? await listener.nextRequest(within: .seconds(30)) else { continue }
                connection.respond(server.handle(rawRequest: connection.request))
            }
        }
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port)")! }

    func stop() async {
        task?.cancel()
        listener.cancel()
        await task?.value
        listener.close()
    }
}

private final class MemoryVault: DesktopCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readCredential(_ name: String) throws -> String? { lock.withLock { values[name] } }
    func writeCredential(_ value: String, name: String) throws { lock.withLock { values[name] = value } }
    func deleteCredential(_ name: String) throws { lock.withLock { values[name] = nil } }
}

/// Connects a plain TCP socket to this computer's loopback address.
private func connectLoopback(port: UInt16) -> Int32? {
    let socket = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard socket >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Glibc.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        Glibc.close(socket)
        return nil
    }
    return socket
}

final class LinuxCloudKitTransportTests: XCTestCase {
    private let apiToken = "synthetic-api-token"
    private let container = "iCloud.com.example.synthetic"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("linux-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// Key-sync metadata and one key as a Mac writes them, sealed here with
    /// the real envelope and 210,000 PBKDF2 iterations.
    private func seedMacKeys(_ fake: FakeCloudKitWebServer, passphrase: String) throws {
        let envelope = EncryptedSecretEnvelope(cryptography: LinuxEnvelopeCryptography())
        let created = try envelope.makeMetadata(passphrase: passphrase)
        let updated = milliseconds(Date(timeIntervalSince1970: 1_800_000_000))
        fake.seedRecord(
            zone: SyncSchema.zoneName, recordName: SyncSchema.KeySyncMetadata.recordName,
            recordType: SyncSchema.KeySyncMetadata.recordType, fields: [
                "salt": (created.metadata.salt.base64EncodedString(), "BYTES"),
                "verifierNonce": (created.metadata.verifierNonce.base64EncodedString(), "BYTES"),
                "verifierCiphertext": (created.metadata.verifierCiphertext.base64EncodedString(), "BYTES"),
                "verifierTag": (created.metadata.verifierTag.base64EncodedString(), "BYTES"),
                "updatedAt": (updated, "TIMESTAMP")
            ]
        )
        let secret = try envelope.seal(
            identifier: "openai.apiKey", value: "synthetic-openai-key", updatedAt: Date(), key: created.key
        )
        fake.seedRecord(
            zone: SyncSchema.zoneName, recordName: SyncSchema.EncryptedSecret.recordName(for: "openai.apiKey"),
            recordType: SyncSchema.EncryptedSecret.recordType, fields: [
                "identifier": ("openai.apiKey", "STRING"),
                "ciphertext": (secret.ciphertext.base64EncodedString(), "BYTES"),
                "nonce": (secret.nonce.base64EncodedString(), "BYTES"),
                "tag": (secret.tag.base64EncodedString(), "BYTES"),
                "updatedAt": (updated, "TIMESTAMP"),
                "isDeleted": (0, "INT64")
            ]
        )
    }

    private func seedMacHistory(_ fake: FakeCloudKitWebServer, id: UUID) {
        let name = id.uuidString
        fake.seedRecord(zone: SyncSchema.zoneName, recordName: name, recordType: "TranscriptionHistory", fields: [
            "entryID": (name, "STRING"),
            "createdAt": (Int64(1_800_000_000_000), "TIMESTAMP"),
            "rawTranscription": ("from the mac", "STRING"),
            "model": ("deepgram/nova-3", "STRING"),
            "duration": (2.5, "DOUBLE"),
            "wordCount": (3, "INT64"),
            "originPlatform": ("macos", "STRING"),
            "updatedAt": (Int64(1_800_000_100_000), "TIMESTAMP")
        ])
    }

    /// The desktop sync service as the Linux app builds it, except for the
    /// fake server's address and an in-memory vault.
    private func makeService(
        baseURL: URL, vault: MemoryVault, records: DesktopRecordingStore
    ) throws -> DesktopCloudSyncService {
        let state = try DesktopCloudSyncStateStore(url: directory.appendingPathComponent("state.json"))
        return DesktopCloudSyncService(
            resolution: .available(try CloudKitWebServicesConfiguration(
                containerIdentifier: container, environment: .production, apiToken: apiToken, baseURL: baseURL
            )),
            transport: LinuxCloudKitTransport(timeout: .seconds(20)),
            vault: vault,
            state: state,
            historyStore: DesktopHistorySyncStore(
                records: records, state: state, origin: DesktopHistorySyncProjection.linuxOriginPlatform
            ),
            cryptography: LinuxEnvelopeCryptography()
        )
    }

    func testHistoryAndKeysSyncThroughURLSessionAndOpenSSL() async throws {
        let fake = FakeCloudKitWebServer(apiToken: apiToken, containerIdentifier: container)
        let macID = UUID()
        seedMacHistory(fake, id: macID)
        try seedMacKeys(fake, passphrase: "correct horse battery staple")
        let loopback = try LoopbackCloudKitServer(server: fake)
        let vault = MemoryVault()
        let signedIn = fake.completeSignIn()
        try vault.writeCredential(signedIn, name: DesktopCloudSyncCredential.webAuthToken)
        let records = try DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
        var local = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "take.wav", modelIdentifier: "openai/whisper-1"
        )
        local.result = TranscriptionResult(
            text: "from linux", segments: [], confidence: nil, duration: 1, modelIdentifier: "openai/whisper-1",
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        try await records.save(local)
        let service = try makeService(baseURL: loopback.baseURL, vault: vault, records: records)

        await service.prepare()
        try await service.setHistoryEnabled(true)
        let imported = try await service.enableKeyImport(passphrase: "correct horse battery staple")
        let pass = await service.sync()
        await loopback.stop()

        XCTAssertNil(pass.error)
        XCTAssertEqual(imported.importedKeys, ["openai.apiKey"])
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "synthetic-openai-key")
        let received = await records.existingRecord(id: macID)
        XCTAssertEqual(received?.result?.text, "from the mac")
        XCTAssertEqual(received?.originPlatform, "macos")
        let uploaded = fake.recordFields(zone: SyncSchema.zoneName, recordName: local.id.uuidString)
        XCTAssertEqual(uploaded?["originPlatform"]?.value as? String, "linux")
        XCTAssertEqual(uploaded?["rawTranscription"]?.value as? String, "from linux")
        let rotated = try vault.readCredential(DesktopCloudSyncCredential.webAuthToken)
        XCTAssertNotNil(rotated)
        XCTAssertNotEqual(rotated, signedIn, "the token rotated through libcurl's response headers")
    }

    func testPlainHTTPIsRefusedExceptOnLoopback() async throws {
        let request = CloudKitWebServicesHTTPRequest(
            method: "GET", url: try XCTUnwrap(URL(string: "http://example.invalid/database")), headers: [:], body: nil
        )
        do {
            _ = try await LinuxCloudKitTransport().send(request, responseLimit: 1024)
            XCTFail("Plain HTTP to a remote host must be refused")
        } catch let error as CloudKitWebServicesTransportError {
            XCTAssertEqual(error, .connectionFailed(retryable: false, description: "Only HTTPS requests are allowed."))
        }
    }

    func testCancellingARequestToASilentPeerReturnsPromptly() async throws {
        let listener = try LinuxLoopbackListener()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(listener.port)/silent"))
        let held = Task { try await listener.nextRequest(within: .seconds(20)) }
        let request = Task {
            try await LinuxCloudKitTransport(timeout: .seconds(30)).send(
                CloudKitWebServicesHTTPRequest(method: "GET", url: url, headers: [:], body: nil), responseLimit: 4096
            )
        }
        let accepted = try await held.value
        let connection = try XCTUnwrap(accepted)
        let started = ContinuousClock.now
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("A cancelled request must not complete")
        } catch is CancellationError {
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        connection.respond(Data())
        listener.close()
    }
}

final class LinuxLoopbackListenerTests: XCTestCase {
    func testTheSignInCallbackIsParsedAnsweredAndTheListenerCloses() async throws {
        let listener = try LinuxLoopbackListener()
        let port = listener.port
        let callback = Task {
            try await DesktopCloudSyncSignIn.awaitCallback(on: listener, within: .seconds(20))
        }
        let stray = try await LinuxCloudKitTransport(timeout: .seconds(20)).send(
            CloudKitWebServicesHTTPRequest(
                method: "GET", url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/favicon.ico")),
                headers: [:], body: nil
            ),
            responseLimit: 4096
        )
        let target = "/cloudkit-sign-in?ckWebAuthToken=abc%2Bdef%3D"
        let reply = try await LinuxCloudKitTransport(timeout: .seconds(20)).send(
            CloudKitWebServicesHTTPRequest(
                method: "GET", url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(target)")),
                headers: [:], body: nil
            ),
            responseLimit: 4096
        )
        let token = try await callback.value
        listener.close()

        XCTAssertEqual(stray.statusCode, 404)
        XCTAssertEqual(token, "abc+def=")
        XCTAssertEqual(reply.statusCode, 200)
        XCTAssertTrue(String(bytes: reply.body, encoding: .utf8)?.contains("You are signed in to iCloud.") == true)
        XCTAssertEqual(reply.header("Cache-Control"), "no-store")
        let late = connectLoopback(port: port)
        if let late { Glibc.close(late) }
        XCTAssertNil(late, "nothing listens once sign-in finished")
    }

    func testIdleAndAbandonedConnectionsDoNotHoldTheCallback() async throws {
        let listener = try LinuxLoopbackListener(requestWindow: .milliseconds(200))
        let port = listener.port
        let callback = Task {
            try await DesktopCloudSyncSignIn.awaitCallback(on: listener, within: .seconds(20))
        }
        // A preconnection that never sends, and one that closes halfway.
        let idle = try XCTUnwrap(connectLoopback(port: port))
        defer { Glibc.close(idle) }
        let abandoned = try XCTUnwrap(connectLoopback(port: port))
        _ = "GET /cloudkit-sign-in?ckWeb".withCString { Glibc.send(abandoned, $0, strlen($0), 0) }
        Glibc.close(abandoned)
        let reply = try await LinuxCloudKitTransport(timeout: .seconds(20)).send(
            CloudKitWebServicesHTTPRequest(
                method: "GET",
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/cloudkit-sign-in?ckWebAuthToken=t1")),
                headers: [:], body: nil
            ),
            responseLimit: 4096
        )
        let token = try await callback.value
        listener.close()

        XCTAssertEqual(reply.statusCode, 200)
        XCTAssertEqual(token, "t1")
    }

    func testAWaitingListenerEndsWhenCancelledOrWhenItsTimeoutPasses() async throws {
        let listener = try LinuxLoopbackListener()
        let started = ContinuousClock.now
        let quiet = try await listener.nextRequest(within: .milliseconds(100))
        XCTAssertNil(quiet)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(90))

        let waiting = Task { try await listener.nextRequest(within: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("A cancelled wait must not return a request")
        } catch is CancellationError {
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        listener.close()
    }

    func testTheCallbackPortCannotBeSharedAndIsFreedOnClose() throws {
        let listener = try LinuxLoopbackListener()
        XCTAssertThrowsError(try LinuxLoopbackListener(port: listener.port)) { error in
            XCTAssertEqual(
                (error as? LinuxNativeError)?.message,
                "Another program is using 127.0.0.1:\(listener.port) on this computer."
            )
        }
        listener.close()
        let reopened = try LinuxLoopbackListener(port: listener.port)
        XCTAssertEqual(reopened.port, listener.port)
        reopened.close()
    }

    func testOnlyApplesHTTPSPagesAreOpened() throws {
        for page in [
            "http://idmsa.apple.com/appleauth/auth/authorize/signin",
            "https://apple.com.example.net/signin",
            "https://user@idmsa.apple.com/signin",
            "https://notapple.com/signin",
            "file:///etc/passwd"
        ] {
            XCTAssertThrowsError(try LinuxSignInPage.open(try XCTUnwrap(URL(string: page)))) { error in
                XCTAssertEqual((error as? LinuxNativeError)?.message, "Only Apple's own sign-in page can be opened.")
            }
        }
    }
}
