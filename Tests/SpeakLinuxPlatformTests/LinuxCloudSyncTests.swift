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

/// GnuTLS must reproduce the API-key envelope exactly: these are the vectors
/// the Apple (CryptoKit) and Windows (CNG) implementations are held to,
/// computed independently with Python hashlib and OpenSSL.
final class LinuxEnvelopeCryptographyTests: XCTestCase {
    private let crypto = LinuxEnvelopeCryptography()
    private let derivedKeyHex = "896bd7f68f1b80b27ed4895a83436bc12858064354495643ed4afc497ee6b775"

    func testPBKDF2MatchesTheStandardVector() throws {
        let derived = try crypto.pbkdf2SHA256(
            password: Data("password".utf8), salt: Data("salt".utf8), iterations: 4_096, keyByteCount: 32
        )
        XCTAssertEqual(derived.hexString, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testTheEnvelopeDerivesTheSameKeyAsAMac() throws {
        let key = try EncryptedSecretEnvelope(cryptography: crypto).deriveKey(
            passphrase: "correct horse battery staple", salt: Data("stable-test-salt".utf8)
        )
        XCTAssertEqual(key.hexString, derivedKeyHex)
    }

    func testGnuTLSOpensWhatAnotherImplementationSealed() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: crypto)
        let key = try XCTUnwrap(Data(hexString: derivedKeyHex))
        let nonce = try XCTUnwrap(Data(hexString: "000102030405060708090a0b"))
        let secret = EncryptedSecret(
            identifier: "openai.apiKey",
            ciphertext: try XCTUnwrap(Data(hexString: "52c3fdc97176744486eb0a499d4213e234b57455f8ea7d")),
            nonce: nonce,
            tag: try XCTUnwrap(Data(hexString: "06a7994a9c79afb5bba6b8b6162449dc")),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
        XCTAssertEqual(try envelope.open(secret, key: key), "synthetic-api-key-value")
        let metadata = KeySyncMetadata(
            salt: Data("stable-test-salt".utf8),
            verifierNonce: nonce,
            verifierCiphertext: try XCTUnwrap(Data(
                hexString: "4bcfe0c96a63654c8eb20450804119f724b56951edb26b9a6125136a26d3da4430281d0dfb21"
            )),
            verifierTag: try XCTUnwrap(Data(hexString: "c0e2d7a8447a27a984ab86407946380e"))
        )
        XCTAssertEqual(try envelope.unlock(metadata, passphrase: "correct horse battery staple"), key)
        XCTAssertThrowsError(try envelope.unlock(metadata, passphrase: "incorrect horse battery staple"))
    }

    func testSealingUsesFreshNoncesAndATamperedTagNeverOpens() throws {
        let envelope = EncryptedSecretEnvelope(cryptography: crypto)
        let key = try XCTUnwrap(Data(hexString: derivedKeyHex))
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

    func testEmptyPlaintextRoundTripsAndRandomBytesDiffer() throws {
        let key = try XCTUnwrap(Data(hexString: derivedKeyHex))
        let sealed = try crypto.sealAESGCM(Data(), key: key)
        XCTAssertEqual(sealed.ciphertext.count, 0)
        XCTAssertEqual(try crypto.openAESGCM(sealed, key: key), Data())
        XCTAssertNotEqual(try crypto.randomBytes(count: 32), try crypto.randomBytes(count: 32))
        XCTAssertThrowsError(try crypto.sealAESGCM(Data("x".utf8), key: Data(repeating: 1, count: 16)))
    }
}

/// The sign-in callback and the fake CloudKit server over real loopback
/// sockets and FoundationNetworking, as the app uses them.
final class LinuxLoopbackTests: XCTestCase {
    func testTheSignInCallbackReturnsTheTokenAndAnswersOtherPathsWith404() async throws {
        let listener = try LinuxLoopbackListener()
        defer { listener.close() }
        let waiting = Task { try await LinuxCloudSyncSignIn.awaitCallback(on: listener, window: .seconds(20)) }
        let stray = try await get("http://127.0.0.1:\(listener.port)/favicon.ico")
        XCTAssertEqual(stray.status, 404)
        let signedIn = try await get(
            "http://127.0.0.1:\(listener.port)\(DesktopCloudSyncSignIn.callbackPath)?ckWebAuthToken=abc%2Bdef%3D"
        )
        XCTAssertEqual(signedIn.status, 200)
        XCTAssertTrue(signedIn.body.contains("signed in to iCloud"))
        let token = try await waiting.value
        XCTAssertEqual(token, "abc+def=")
    }

    func testTheCallbackUsesTheSameURLAsWindows() {
        XCTAssertEqual(DesktopCloudSyncSignIn.callbackURL, "http://127.0.0.1:47823/cloudkit-sign-in")
    }

    func testWaitingForTheCallbackTimesOutAndCancels() async throws {
        let listener = try LinuxLoopbackListener()
        defer { listener.close() }
        do {
            _ = try await LinuxCloudSyncSignIn.awaitCallback(on: listener, window: .milliseconds(200))
            XCTFail("An unanswered sign-in must time out")
        } catch let failure as LinuxLoopbackListener.Failure {
            XCTAssertEqual(failure, .timedOut)
        }
        let waiting = Task { try await LinuxCloudSyncSignIn.awaitCallback(on: listener, window: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("A cancelled sign-in must not return a token")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testThePortInUseIsReportedPlainly() throws {
        let first = try LinuxLoopbackListener()
        defer { first.close() }
        XCTAssertThrowsError(try LinuxLoopbackListener(port: first.port)) { error in
            XCTAssertTrue(error.localizedDescription.contains("port \(first.port)"))
        }
    }

    func testHistorySyncsThroughURLSessionAgainstTheFakeServerOnLoopback() async throws {
        let apiToken = "synthetic-api-token"
        let container = "iCloud.com.example.synthetic"
        let fake = FakeCloudKitWebServer(apiToken: apiToken, containerIdentifier: container)
        let macID = UUID()
        fake.seedRecord(zone: SyncSchema.zoneName, recordName: macID.uuidString, recordType: "TranscriptionHistory",
                        fields: [
            "entryID": (macID.uuidString, "STRING"),
            "createdAt": (1_800_000_000_000, "TIMESTAMP"),
            "rawTranscription": ("from the mac", "STRING"),
            "model": ("deepgram/nova-3", "STRING"),
            "duration": (2.5, "DOUBLE"),
            "wordCount": (3, "INT64"),
            "originPlatform": ("macos", "STRING"),
            "updatedAt": (1_800_000_100_000, "TIMESTAMP")
        ])
        let listener = try LinuxLoopbackListener(maximumRequestBytes: 4 * 1024 * 1024)
        let serving = Task.detached {
            while !Task.isCancelled {
                guard let connection = try? await listener.accept(timeout: .seconds(30)) else { continue }
                connection.respond(fake.handle(rawRequest: connection.request))
            }
        }
        defer {
            serving.cancel()
            listener.cancel()
        }
        let tokens = MemoryTokenStore(token: fake.completeSignIn())
        let client = CloudKitWebServicesClient(
            configuration: try CloudKitWebServicesConfiguration(
                containerIdentifier: container, environment: .production, apiToken: apiToken,
                baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(listener.port)"))
            ),
            tokenStore: tokens,
            transport: URLSessionCloudKitWebServicesTransport(deadline: .seconds(20))
        )
        let initial = await tokens.token
        let identity = try await client.currentUserRecordName()
        let transport = try CloudKitWebHistorySyncTransport(
            client: client, consent: CloudKitWebSyncConsent(enabledFeatures: [.history])
        )
        let page = try await transport.fetchChanges(after: nil)
        let received = page.changes.compactMap { change -> String? in
            if case .changed(let entry) = change { return entry.rawTranscription }
            return nil
        }
        XCTAssertEqual(identity, "_synthetic-user-a")
        XCTAssertEqual(received, ["from the mac"])
        let rotated = await tokens.token
        XCTAssertNotEqual(rotated, initial, "The web auth token rotates through FoundationNetworking's headers")
    }

    private func get(_ address: String) async throws -> (status: Int, body: String) {
        let url = try XCTUnwrap(URL(string: address))
        let (data, response) = try await URLSession.shared.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(bytes: data, encoding: .utf8) ?? "")
    }
}

private actor MemoryTokenStore: CloudKitWebAuthTokenStore {
    private(set) var token: String?
    init(token: String?) { self.token = token }
    func loadWebAuthToken() async throws -> String? { token }
    func saveWebAuthToken(_ token: String) async throws { self.token = token }
    func clearWebAuthToken() async throws { token = nil }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
