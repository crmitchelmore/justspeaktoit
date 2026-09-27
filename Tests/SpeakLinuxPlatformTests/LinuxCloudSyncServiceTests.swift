import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import SpeakLinuxPlatform
import SpeakSync
import SpeakTestSupport
import XCTest

/// The Linux sync service end to end against `FakeCloudKitWebServer`: the
/// browser sign-in through the real loopback listener, History both ways, and
/// opt-in import of the Mac's passphrase-sealed keys with GnuTLS.
final class LinuxCloudSyncServiceTests: XCTestCase {
    private let apiToken = "synthetic-api-token"
    private let passphrase = "correct horse battery staple"
    private var directory: URL!
    private var server: FakeCloudKitWebServer!
    private var vault: SyncMemoryVault!
    private var records: DesktopRecordingStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("linux-sync-\(UUID().uuidString)")
        server = FakeCloudKitWebServer(apiToken: apiToken, containerIdentifier: "iCloud.com.justspeaktoit")
        vault = SyncMemoryVault()
        records = try DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeService() throws -> DesktopCloudSyncService {
        let state = try DesktopCloudSyncStateStore(url: directory.appendingPathComponent("state.json"))
        let history = DesktopHistorySyncStore(records: records, state: state, onChanges: { _ in })
        return DesktopCloudSyncService(
            resolution: DesktopCloudSyncConfiguration.resolve(
                buildToken: apiToken, buildEnvironment: "production", processEnvironment: [:], train: .stable
            ),
            transport: SyncFakeTransport(server: server),
            vault: vault,
            state: state,
            historyStore: history,
            cryptography: LinuxEnvelopeCryptography(),
            sleep: { _ in }
        )
    }

    /// Signs in the way the app does: the browser is sent to the callback URL
    /// with the token Apple's page would add.
    private func signIn(_ service: DesktopCloudSyncService) async throws {
        let page = try await service.signInPage()
        XCTAssertEqual(page?.absoluteString, FakeCloudKitWebServer.signInURL)
        let listener = try LinuxLoopbackListener()
        defer { listener.close() }
        let waiting = Task { try await LinuxCloudSyncSignIn.awaitCallback(on: listener, window: .seconds(20)) }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(listener.port)
        components.path = DesktopCloudSyncSignIn.callbackPath
        components.queryItems = [URLQueryItem(name: "ckWebAuthToken", value: server.completeSignIn())]
        let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(components.url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        try await service.completeSignIn(webAuthToken: try await waiting.value)
    }

    func testSignInThenHistorySyncsBothWays() async throws {
        let service = try makeService()
        await service.prepare()
        var status = await service.status()
        XCTAssertFalse(status.isSignedIn)
        try await signIn(service)
        XCTAssertNotNil(try vault.readCredential(DesktopCloudSyncCredential.webAuthToken),
                        "The web auth token is kept in the keyring vault")
        let macID = UUID()
        seedMacHistory(id: macID, raw: "dictated on the mac")
        var local = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "take.wav", modelIdentifier: "openai/whisper-1"
        )
        local.result = TranscriptionResult(
            text: "dictated on linux", segments: [], confidence: nil, duration: 2, modelIdentifier: "openai/whisper-1",
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        try await records.save(local)

        // Nothing syncs until History is chosen.
        _ = await service.sync()
        let beforeConsent = await records.existingRecord(id: macID)
        XCTAssertNil(beforeConsent)
        XCTAssertNil(server.recordFields(zone: SyncSchema.zoneName, recordName: local.id.uuidString))

        try await service.setHistoryEnabled(true)
        let report = await service.sync()
        XCTAssertNil(report.error)
        let received = await records.existingRecord(id: macID)
        XCTAssertEqual(received?.result?.text, "dictated on the mac")
        let uploaded = server.recordFields(zone: SyncSchema.zoneName, recordName: local.id.uuidString)
        XCTAssertEqual(uploaded?["rawTranscription"]?.value as? String, "dictated on linux")
        status = await service.status()
        XCTAssertTrue(status.isSignedIn)
        XCTAssertTrue(status.historyEnabled)
    }

    func testKeyImportIsOptInAndNeedsTheMacPassphrase() async throws {
        let service = try makeService()
        try await signIn(service)
        try seedMacKeys(["openai.apiKey": "sk-synthetic-openai"])
        try await service.setHistoryEnabled(true)
        _ = await service.sync()
        XCTAssertNil(try vault.readCredential("openai.apiKey"), "Keys are never imported without opting in")
        XCTAssertNil(try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey))

        do {
            _ = try await service.enableKeyImport(passphrase: "incorrect horse battery staple")
            XCTFail("A wrong passphrase must be refused")
        } catch {}
        XCTAssertNil(try vault.readCredential("openai.apiKey"))

        let report = try await service.enableKeyImport(passphrase: passphrase)
        XCTAssertEqual(report.importedKeys, ["openai.apiKey"])
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "sk-synthetic-openai")
        XCTAssertNotNil(try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey),
                        "The derived key, never the passphrase, is kept in the keyring vault")
        let status = await service.status()
        XCTAssertTrue(status.apiKeyImportEnabled)

        try await service.disableKeyImport()
        let disabled = await service.status()
        XCTAssertFalse(disabled.apiKeyImportEnabled)
    }

    // MARK: - Fixtures

    private func seedMacHistory(id: UUID, raw: String) {
        server.seedRecord(zone: SyncSchema.zoneName, recordName: id.uuidString, recordType: "TranscriptionHistory",
                          fields: [
            "entryID": (id.uuidString, "STRING"),
            "createdAt": (1_800_000_000_000, "TIMESTAMP"),
            "rawTranscription": (raw, "STRING"),
            "model": ("deepgram/nova-3", "STRING"),
            "duration": (4.0, "DOUBLE"),
            "wordCount": (4, "INT64"),
            "originPlatform": ("macos", "STRING"),
            "updatedAt": (1_800_000_100_000, "TIMESTAMP")
        ])
    }

    /// Key-sync metadata and keys as a Mac writes them, sealed with real AES-GCM.
    private func seedMacKeys(_ keys: [String: String]) throws {
        let envelope = EncryptedSecretEnvelope(cryptography: LinuxEnvelopeCryptography())
        let created = try envelope.makeMetadata(passphrase: passphrase)
        server.seedRecord(zone: SyncSchema.zoneName, recordName: "api-key-sync-metadata",
                          recordType: "EncryptedSecretMetadata", fields: [
            "salt": (created.metadata.salt.base64EncodedString(), "BYTES"),
            "verifierNonce": (created.metadata.verifierNonce.base64EncodedString(), "BYTES"),
            "verifierCiphertext": (created.metadata.verifierCiphertext.base64EncodedString(), "BYTES"),
            "verifierTag": (created.metadata.verifierTag.base64EncodedString(), "BYTES"),
            "updatedAt": (1_800_000_000_000, "TIMESTAMP")
        ])
        for (identifier, value) in keys {
            let secret = try envelope.seal(
                identifier: identifier, value: value, updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
                key: created.key
            )
            let name = SyncSchema.EncryptedSecret.recordName(for: identifier)
            server.seedRecord(zone: SyncSchema.zoneName, recordName: name, recordType: "EncryptedSecret", fields: [
                "identifier": (identifier, "STRING"),
                "ciphertext": (secret.ciphertext.base64EncodedString(), "BYTES"),
                "nonce": (secret.nonce.base64EncodedString(), "BYTES"),
                "tag": (secret.tag.base64EncodedString(), "BYTES"),
                "updatedAt": (1_800_000_100_000, "TIMESTAMP"),
                "isDeleted": (0, "INT64")
            ])
        }
    }
}

/// Routes the shared client to the stateful fake server.
private struct SyncFakeTransport: CloudKitWebServicesHTTPTransport {
    let server: FakeCloudKitWebServer

    func send(
        _ request: CloudKitWebServicesHTTPRequest, responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse {
        let response = server.handle(method: request.method, url: request.url, body: request.body)
        return CloudKitWebServicesHTTPResponse(
            statusCode: response.status, headers: response.headers, body: response.body
        )
    }
}

/// The Secret Service stand-in; the keyring itself is covered by the integration checks.
private final class SyncMemoryVault: DesktopCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readCredential(_ name: String) throws -> String? { lock.withLock { values[name] } }
    func writeCredential(_ value: String, name: String) throws { lock.withLock { values[name] = value } }
    func deleteCredential(_ name: String) throws { lock.withLock { values[name] = nil } }
}
