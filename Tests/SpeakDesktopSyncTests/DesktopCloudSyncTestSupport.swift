import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import SpeakSync
import SpeakTestSupport
import XCTest

let apiToken = "synthetic-api-token"
let zone = SyncSchema.zoneName

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
    server.seedRecord(zone: zone, recordName: id.uuidString, recordType: "TranscriptionHistory", fields: fields)
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
            transport: FakeServerTransport(server: server),
            vault: vault,
            state: state,
            historyStore: history,
            cryptography: ToyCryptography(),
            sleep: { _ in }
        )
        return (service, state)
    }

    func signedInService(
        onChanges: @escaping @Sendable ([DesktopHistorySyncChange]) async -> Void = { _ in }
    ) async throws -> (DesktopCloudSyncService, DesktopCloudSyncStateStore) {
        let (service, state) = try makeService(onChanges: onChanges)
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

actor ChangeLog {
    private(set) var all: [DesktopHistorySyncChange] = []
    func append(_ changes: [DesktopHistorySyncChange]) { all += changes }
}
