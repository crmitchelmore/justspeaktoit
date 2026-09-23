import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import SpeakSync
import SpeakTestSupport
import XCTest

let apiToken = "synthetic-api-token"
let syncZone = SyncSchema.zoneName

/// Routes the shared client to the stateful fake CloudKit server.
struct FakeServerTransport: CloudKitWebServicesHTTPTransport {
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

/// Credential Manager stand-in.
final class MemoryVault: DesktopCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readCredential(_ name: String) throws -> String? { lock.withLock { values[name] } }
    func writeCredential(_ value: String, name: String) throws { lock.withLock { values[name] = value } }
    func deleteCredential(_ name: String) throws { lock.withLock { values[name] = nil } }
}

/// Deterministic keyed stand-in primitives (not cryptography), so the envelope
/// flow runs anywhere. Windows checks its CNG provider with real vectors.
struct ToyCryptography: SyncEnvelopeCryptography {
    func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data {
        var key = [UInt8](repeating: 7, count: keyByteCount)
        for (index, byte) in (password + salt).enumerated() {
            key[index % keyByteCount] = key[index % keyByteCount] &* 33 &+ byte
        }
        return Data(key)
    }

    func sealAESGCM(_ plaintext: Data, key: Data) throws -> SealedEnvelopePayload {
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let ciphertext = Data(plaintext.enumerated().map { $0.element ^ key[$0.offset % 32] ^ nonce[$0.offset % 12] })
        return SealedEnvelopePayload(nonce: nonce, ciphertext: ciphertext, tag: tag(ciphertext, key, nonce))
    }

    func openAESGCM(_ sealed: SealedEnvelopePayload, key: Data) throws -> Data {
        guard tag(sealed.ciphertext, key, sealed.nonce) == sealed.tag else {
            throw CloudKitKeySyncError.encryptionFailed
        }
        return Data(sealed.ciphertext.enumerated().map {
            $0.element ^ key[$0.offset % 32] ^ sealed.nonce[$0.offset % 12]
        })
    }

    func randomBytes(count: Int) throws -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }

    private func tag(_ ciphertext: Data, _ key: Data, _ nonce: Data) -> Data {
        var tag = [UInt8](repeating: 3, count: 16)
        for (index, byte) in (key + nonce + ciphertext).enumerated() {
            tag[index % 16] = tag[index % 16] &* 131 &+ byte
        }
        return Data(tag)
    }
}

func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

/// A fixed instant `seconds` after the fixtures' base time.
func fixtureDate(_ seconds: Int) -> Date {
    Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(seconds))
}

func seedMacHistory(
    _ server: FakeCloudKitWebServer, id: UUID, raw: String, processed: String? = nil, updatedAt: Date
) {
    var fields: [String: (value: Any, type: String)] = [
        "entryID": (id.uuidString, "STRING"),
        "createdAt": (milliseconds(fixtureDate(0)), "TIMESTAMP"),
        "rawTranscription": (raw, "STRING"),
        "model": ("deepgram/nova-3", "STRING"),
        "duration": (4.0, "DOUBLE"),
        "wordCount": (3, "INT64"),
        "originPlatform": ("macos", "STRING"),
        "updatedAt": (milliseconds(updatedAt), "TIMESTAMP")
    ]
    if let processed { fields["postProcessedText"] = (processed, "STRING") }
    server.seedRecord(zone: syncZone, recordName: id.uuidString, recordType: "TranscriptionHistory", fields: fields)
}

/// Shared fixture: a fake server, an in-memory vault and a temporary History.
class DesktopCloudSyncTestCase: XCTestCase {
    var directory: URL!
    var server: FakeCloudKitWebServer!
    var vault: MemoryVault!
    var records: DesktopRecordingStore!
    var clock: Date = Date(timeIntervalSince1970: 1_900_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-sync-\(UUID().uuidString)")
        server = FakeCloudKitWebServer(apiToken: apiToken, containerIdentifier: "iCloud.com.justspeaktoit")
        vault = MemoryVault()
        records = try DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeService(
        transport: (any CloudKitWebServicesHTTPTransport)? = nil,
        onChanges: @escaping @Sendable ([DesktopHistorySyncChange]) async -> Void = { _ in }
    ) throws -> (DesktopCloudSyncService, DesktopCloudSyncStateStore) {
        let state = try DesktopCloudSyncStateStore(url: directory.appendingPathComponent("cloud-sync.json"))
        let clockValue = clock
        let history = DesktopHistorySyncStore(records: records, state: state, now: { clockValue }, onChanges: onChanges)
        let resolution = DesktopCloudSyncConfiguration.resolve(
            buildToken: apiToken, buildEnvironment: "production", processEnvironment: [:], train: .stable
        )
        let service = DesktopCloudSyncService(
            resolution: resolution,
            transport: transport ?? FakeServerTransport(server: server),
            vault: vault,
            state: state,
            historyStore: history,
            cryptography: ToyCryptography(),
            sleep: { _ in }
        )
        return (service, state)
    }

    func signedInService(
        transport: (any CloudKitWebServicesHTTPTransport)? = nil,
        onChanges: @escaping @Sendable ([DesktopHistorySyncChange]) async -> Void = { _ in }
    ) async throws -> (DesktopCloudSyncService, DesktopCloudSyncStateStore) {
        let (service, state) = try makeService(transport: transport, onChanges: onChanges)
        let page = try await service.signInPage()
        XCTAssertEqual(page?.absoluteString, FakeCloudKitWebServer.signInURL)
        try await service.completeSignIn(webAuthToken: server.completeSignIn())
        try await service.setHistoryEnabled(true)
        return (service, state)
    }

    func localRecording(text: String, processed: String? = nil) async throws -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "take.wav", modelIdentifier: "openai/whisper-1"
        )
        record.result = TranscriptionResult(
            text: text, segments: [], confidence: nil, duration: 2, modelIdentifier: "openai/whisper-1",
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        record.processedText = processed
        try await records.save(record)
        return record
    }
}

extension DesktopCloudSyncTestCase {
    /// Key-sync metadata and keys as a Mac writes them, sealed with `passphrase`.
    func seedMacKeys(passphrase: String, keys: [String: String], deleted: [String] = []) throws {
        let envelope = EncryptedSecretEnvelope(cryptography: ToyCryptography())
        let created = try envelope.makeMetadata(passphrase: passphrase)
        let name = "api-key-sync-metadata"
        server.seedRecord(zone: syncZone, recordName: name, recordType: "EncryptedSecretMetadata", fields: [
            "salt": (created.metadata.salt.base64EncodedString(), "BYTES"),
            "verifierNonce": (created.metadata.verifierNonce.base64EncodedString(), "BYTES"),
            "verifierCiphertext": (created.metadata.verifierCiphertext.base64EncodedString(), "BYTES"),
            "verifierTag": (created.metadata.verifierTag.base64EncodedString(), "BYTES"),
            "updatedAt": (milliseconds(fixtureDate(0)), "TIMESTAMP")
        ])
        try seedSecrets(keys, deleted: deleted, key: created.key, at: fixtureDate(100))
    }

    /// Later key changes on the Mac, sealed with `key` or the key this device stored.
    func seedSecrets(_ keys: [String: String], deleted: [String] = [], key: Data? = nil, at date: Date) throws {
        let envelope = EncryptedSecretEnvelope(cryptography: ToyCryptography())
        let stored = try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey)
        let key = try key ?? XCTUnwrap(stored.flatMap { Data(base64Encoded: $0) })
        let entries = keys.map { ($0.key, $0.value, false) } + deleted.map { ($0, "", true) }
        for (identifier, value, isDeleted) in entries {
            let secret = try envelope.seal(
                identifier: identifier, value: value, updatedAt: date, key: key, isDeleted: isDeleted
            )
            server.seedRecord(zone: syncZone, recordName: SyncSchema.EncryptedSecret.recordName(for: identifier),
                              recordType: "EncryptedSecret", fields: [
                "identifier": (identifier, "STRING"),
                "ciphertext": (secret.ciphertext.base64EncodedString(), "BYTES"),
                "nonce": (secret.nonce.base64EncodedString(), "BYTES"),
                "tag": (secret.tag.base64EncodedString(), "BYTES"),
                "updatedAt": (milliseconds(date), "TIMESTAMP"),
                "isDeleted": (isDeleted ? 1 : 0, "INT64")
            ])
        }
    }
}

actor ChangeLog {
    private(set) var all: [DesktopHistorySyncChange] = []
    func append(_ changes: [DesktopHistorySyncChange]) { all += changes }
}

/// Routes to the fake server like `FakeServerTransport`, notes every request,
/// and can hold requests for one operation without observing cancellation, as
/// a transport that cannot abandon a request in flight would.
actor RecordingServerTransport: CloudKitWebServicesHTTPTransport {
    struct Sent: Sendable {
        /// For example `private/records/modify`.
        let operation: String
        let body: String
    }

    private let server: FakeCloudKitWebServer
    private(set) var sent: [Sent] = []
    private var heldOperation: String?
    private var held: [CheckedContinuation<Void, Never>] = []

    init(server: FakeCloudKitWebServer) {
        self.server = server
    }

    var heldCount: Int { held.count }

    func hold(_ operation: String) {
        heldOperation = operation
    }

    func releaseHeld() {
        heldOperation = nil
        let waiting = held
        held.removeAll()
        waiting.forEach { $0.resume() }
    }

    func send(
        _ request: CloudKitWebServicesHTTPRequest,
        responseLimit: Int
    ) async throws -> CloudKitWebServicesHTTPResponse {
        // `/database/1/<container>/<environment>/<database>/<operation…>`
        let operation = request.url.path.split(separator: "/").dropFirst(4).joined(separator: "/")
        let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        sent.append(Sent(operation: operation, body: body))
        if operation == heldOperation {
            await withCheckedContinuation { held.append($0) }
        }
        let response = server.handle(method: request.method, url: request.url, body: request.body)
        return CloudKitWebServicesHTTPResponse(
            statusCode: response.status, headers: response.headers, body: response.body
        )
    }
}

/// Holds the first History change report until released, as a slow window
/// would, leaving the sync pass waiting between two of its steps.
actor ChangeGate {
    private var hasHeld = false
    private var waiter: CheckedContinuation<Void, Never>?
    /// Every change the window was told about, in order.
    private(set) var reported: [DesktopHistorySyncChange] = []

    var isHolding: Bool { waiter != nil }

    func report(_ changes: [DesktopHistorySyncChange]) async {
        reported += changes
        guard !hasHeld else { return }
        hasHeld = true
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

enum DesktopSyncTestError: Error {
    case conditionNotMet
}

/// Polls an asynchronous condition, yielding between checks, until it holds
/// or `timeout` passes. The deadline only bounds a failing test.
func eventually(
    within timeout: Duration = .seconds(10),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Condition was not satisfied within \(timeout)", file: file, line: line)
    throw DesktopSyncTestError.conditionNotMet
}
