#if os(Windows)
import Foundation
import CWindowsSupport
import SpeakSync
import SpeakTestSupport
import XCTest
@testable import SpeakWindowsPlatform

/// CNG must reproduce the API-key envelope exactly: these vectors were computed
/// independently (Python hashlib and OpenSSL) and are the same ones the Apple
/// CryptoKit implementation is held to.
final class WindowsEnvelopeCryptographyTests: XCTestCase {
    private let crypto = WindowsEnvelopeCryptography()
    private let derivedKeyHex = "896bd7f68f1b80b27ed4895a83436bc12858064354495643ed4afc497ee6b775"

    func testPBKDF2MatchesTheStandardVector() throws {
        let derived = try crypto.pbkdf2SHA256(
            password: Data("password".utf8), salt: Data("salt".utf8), iterations: 4_096, keyByteCount: 32
        )
        XCTAssertEqual(derived.hex, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testTheEnvelopeDerivesTheSameKeyAsAMac() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: crypto)
        let key = try envelope.deriveKey(
            passphrase: "correct horse battery staple", salt: Data("stable-test-salt".utf8)
        )
        XCTAssertEqual(key.hex, derivedKeyHex)
    }

    func testCNGOpensWhatAnotherImplementationSealed() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: crypto)
        let key = try XCTUnwrap(Data(hex: derivedKeyHex))
        let nonce = try XCTUnwrap(Data(hex: "000102030405060708090a0b"))
        let secret = EncryptedSecret(
            identifier: "openai.apiKey",
            ciphertext: try XCTUnwrap(Data(hex: "52c3fdc97176744486eb0a499d4213e234b57455f8ea7d")),
            nonce: nonce,
            tag: try XCTUnwrap(Data(hex: "06a7994a9c79afb5bba6b8b6162449dc")),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
        XCTAssertEqual(try envelope.open(secret, key: key), "synthetic-api-key-value")

        let metadata = KeySyncMetadata(
            salt: Data("stable-test-salt".utf8),
            verifierNonce: nonce,
            verifierCiphertext: try XCTUnwrap(Data(
                hex: "4bcfe0c96a63654c8eb20450804119f724b56951edb26b9a6125136a26d3da4430281d0dfb21"
            )),
            verifierTag: try XCTUnwrap(Data(hex: "c0e2d7a8447a27a984ab86407946380e"))
        )
        XCTAssertEqual(try envelope.unlock(metadata, passphrase: "correct horse battery staple"), key)
        XCTAssertThrowsError(try envelope.unlock(metadata, passphrase: "incorrect horse battery staple"))
    }

    func testSealingUsesFreshNoncesAndATamperedTagNeverOpens() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: crypto)
        let key = try XCTUnwrap(Data(hex: derivedKeyHex))
        let first = try envelope.seal(identifier: "openai.apiKey", value: "synthetic", updatedAt: Date(), key: key)
        let second = try envelope.seal(identifier: "openai.apiKey", value: "synthetic", updatedAt: Date(), key: key)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertEqual(try envelope.open(first, key: key), "synthetic")
        var tag = first.tag
        tag[tag.startIndex] ^= 1
        let tampered = EncryptedSecret(
            identifier: first.identifier, ciphertext: first.ciphertext, nonce: first.nonce, tag: tag,
            updatedAt: first.updatedAt
        )
        XCTAssertThrowsError(try envelope.open(tampered, key: key))
        XCTAssertThrowsError(try envelope.open(first, key: Data(repeating: 0, count: 32)))
    }
}

/// Serves the stateful fake CloudKit server on a real loopback socket, so
/// requests go through WinHTTP exactly as they do against iCloud.
final class LoopbackCloudKitServer: @unchecked Sendable {
    let server: FakeCloudKitWebServer
    let listener: WindowsLoopbackListener
    private var task: Task<Void, Never>?

    init(server: FakeCloudKitWebServer) throws {
        self.server = server
        listener = try WindowsLoopbackListener()
        let listener = listener
        task = Task.detached {
            while !Task.isCancelled {
                guard let connection = try? await listener.accept(timeout: .seconds(30)) else { continue }
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

private actor MemoryTokens: CloudKitWebAuthTokenStore {
    private(set) var token: String?
    init(token: String?) { self.token = token }
    func loadWebAuthToken() async throws -> String? { token }
    func saveWebAuthToken(_ token: String) async throws { self.token = token }
    func clearWebAuthToken() async throws { token = nil }
}

private actor MemoryCursor: SyncChangeTokenStore {
    private(set) var token: Data?
    func loadChangeToken() async throws -> Data? { token }
    func saveChangeToken(_ token: Data) async throws { self.token = token }
    func clearChangeToken() async throws { token = nil }
}

private actor MemoryHistory: HistorySyncStore {
    private var local: [UUID: SyncableHistoryEntry]
    private var acknowledged: Set<UUID> = []
    private(set) var received: [SyncableHistoryEntry] = []

    init(local: [SyncableHistoryEntry]) {
        self.local = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
    }

    func pendingEntries() async -> [SyncableHistoryEntry] {
        local.values.filter { !acknowledged.contains($0.id) }
    }

    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        received.append(entry)
        local[entry.id] = entry
        acknowledged.insert(entry.id)
    }

    func didDeleteRemoteEntry(id: UUID) async { local[id] = nil }
    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async { acknowledged.formUnion(ids) }
    func persistRemoteChanges() async throws {}
}

private actor CoordinatorHost {
    let coordinator: HistorySyncCoordinator

    init(transport: any HistorySyncTransport, cursor: any SyncChangeTokenStore) {
        coordinator = HistorySyncCoordinator(transport: transport, tokenStore: cursor, cloudAvailable: true)
    }

    func sync(_ store: any HistorySyncStore) async -> String? {
        await coordinator.sync(store: store)
        return coordinator.status.error.map { String(describing: $0) }
    }
}

final class WinHTTPCloudKitTransportTests: XCTestCase {
    private let apiToken = "synthetic-api-token"
    private let container = "iCloud.com.example.synthetic"

    func testHistorySyncsThroughWinHTTPWithRotatingTokens() async throws {
        let fake = FakeCloudKitWebServer(apiToken: apiToken, containerIdentifier: container)
        let macID = UUID()
        let name = macID.uuidString
        fake.seedRecord(zone: SyncSchema.zoneName, recordName: name, recordType: "TranscriptionHistory", fields: [
            "entryID": (macID.uuidString, "STRING"),
            "createdAt": (1_800_000_000_000, "TIMESTAMP"),
            "rawTranscription": ("from the mac", "STRING"),
            "model": ("deepgram/nova-3", "STRING"),
            "duration": (2.5, "DOUBLE"),
            "wordCount": (3, "INT64"),
            "originPlatform": ("macos", "STRING"),
            "updatedAt": (1_800_000_100_000, "TIMESTAMP")
        ])
        let loopback = try LoopbackCloudKitServer(server: fake)
        let tokens = MemoryTokens(token: fake.completeSignIn())
        let client = CloudKitWebServicesClient(
            configuration: try CloudKitWebServicesConfiguration(
                containerIdentifier: container, environment: .production, apiToken: apiToken,
                baseURL: loopback.baseURL
            ),
            tokenStore: tokens,
            transport: WinHTTPCloudKitTransport(timeout: .seconds(20))
        )
        let windows = SyncableHistoryEntry(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000), rawTranscription: "from windows",
            postProcessedText: nil, model: "openai/whisper-1", duration: 1, wordCount: 2, originPlatform: "windows",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_050)
        )
        let store = MemoryHistory(local: [windows])
        let initialToken = await tokens.token

        let identity = try await client.currentUserRecordName()
        let host = CoordinatorHost(
            transport: try CloudKitWebHistorySyncTransport(
                client: client, consent: CloudKitWebSyncConsent(enabledFeatures: [.history])
            ),
            cursor: MemoryCursor()
        )
        let failure = await host.sync(store)
        await loopback.stop()

        XCTAssertEqual(identity, "_synthetic-user-a")
        XCTAssertNil(failure)
        let received = await store.received
        XCTAssertEqual(received.map(\.rawTranscription), ["from the mac"])
        let uploaded = fake.recordFields(zone: SyncSchema.zoneName, recordName: windows.id.uuidString)
        XCTAssertEqual(uploaded?["originPlatform"]?.value as? String, "windows")
        let finalToken = await tokens.token
        XCTAssertNotNil(finalToken)
        XCTAssertNotEqual(finalToken, initialToken, "The token rotated through WinHTTP response headers")
    }

    func testPlainHTTPIsRefusedExceptOnLoopback() async throws {
        let request = CloudKitWebServicesHTTPRequest(
            method: "GET", url: try XCTUnwrap(URL(string: "http://example.invalid/database")), headers: [:], body: nil
        )
        do {
            _ = try await WinHTTPCloudKitTransport().send(request, responseLimit: 1024)
            XCTFail("Plain HTTP to a remote host must be refused")
        } catch let error as CloudKitWebServicesTransportError {
            XCTAssertEqual(error, .connectionFailed(retryable: false, description: "Only HTTPS requests are allowed."))
        }
    }

    func testTheSignInCallbackArrivesOnTheLoopbackListener() async throws {
        let listener = try WindowsLoopbackListener()
        let target = "/cloudkit-sign-in?ckWebAuthToken=abc%2Bdef%3D"
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(listener.port)" + target))
        let accepted = Task { try await listener.accept(timeout: .seconds(20)) }
        let reply = Task {
            try await WinHTTPCloudKitTransport(timeout: .seconds(20)).send(
                CloudKitWebServicesHTTPRequest(method: "GET", url: url, headers: [:], body: nil), responseLimit: 4096
            )
        }
        let connection = try await accepted.value
        let received = try XCTUnwrap(connection.target)
        connection.respond(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8))
        let response = try await reply.value
        listener.close()

        XCTAssertEqual(received, target)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(bytes: response.body, encoding: .utf8), "ok")
    }

    func testCancellingARequestToASilentPeerReturnsPromptly() async throws {
        let listener = try WindowsLoopbackListener()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(listener.port)/silent"))
        let held = Task { try await listener.accept(timeout: .seconds(20)) }
        let request = Task {
            try await WinHTTPCloudKitTransport(timeout: .seconds(30)).send(
                CloudKitWebServicesHTTPRequest(method: "GET", url: url, headers: [:], body: nil), responseLimit: 4096
            )
        }
        let connection = try await held.value
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

private extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
#endif
