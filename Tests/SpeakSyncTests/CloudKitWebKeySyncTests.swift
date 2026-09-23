import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakSync

/// Reading the Mac's passphrase-encrypted API keys through the fake server.
/// The records are written through the same envelope a Mac uses; the
/// primitives are a deterministic stand-in (not cryptography) so the control
/// flow runs on every platform. Real providers are checked with known-answer
/// vectors in `EncryptedSecretEnvelopeTests` and the Windows platform tests.
final class CloudKitWebKeySyncTests: XCTestCase {
    private let passphrase = "correct horse battery staple"
    private let consent = CloudKitWebSyncConsent(enabledFeatures: [.apiKeys])
    private var server: FakeCloudKitWebServer!
    private var client: CloudKitWebServicesClient!
    private let envelope = EncryptedSecretEnvelope(cryptography: ToyEnvelopeCryptography(), iterations: 2)

    override func setUp() async throws {
        server = FakeCloudKitWebServer(
            apiToken: CloudKitWebFixture.apiToken,
            containerIdentifier: CloudKitWebFixture.containerIdentifier
        )
        client = CloudKitWebServicesClient(
            configuration: try CloudKitWebFixture.configuration(),
            tokenStore: MemoryWebAuthTokenStore(token: server.completeSignIn()),
            transport: FakeServerTransport(server: server),
            sleep: { _ in }
        )
    }

    /// Seeds the metadata record and returns the derived key, as a Mac enabling key sync does.
    private func seedMetadata(passphrase: String? = nil) throws -> Data {
        let created = try envelope.makeMetadata(passphrase: passphrase ?? self.passphrase)
        let metadata = created.metadata
        server.seedRecord(
            zone: SyncSchema.zoneName,
            recordName: SyncSchema.KeySyncMetadata.recordName,
            recordType: SyncSchema.KeySyncMetadata.recordType,
            fields: [
                "salt": (metadata.salt.base64EncodedString(), "BYTES"),
                "verifierNonce": (metadata.verifierNonce.base64EncodedString(), "BYTES"),
                "verifierCiphertext": (metadata.verifierCiphertext.base64EncodedString(), "BYTES"),
                "verifierTag": (metadata.verifierTag.base64EncodedString(), "BYTES"),
                "updatedAt": (CloudKitWebFixture.milliseconds(Date(timeIntervalSince1970: 1_800_000_000)), "TIMESTAMP")
            ]
        )
        return created.key
    }

    private func seedSecret(
        _ identifier: String,
        value: String,
        key: Data,
        deleted: Bool = false,
        storedIdentifier: String? = nil
    ) throws {
        let secret = try envelope.seal(
            identifier: storedIdentifier ?? identifier,
            value: value,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_500),
            key: key,
            isDeleted: deleted
        )
        server.seedRecord(
            zone: SyncSchema.zoneName,
            recordName: SyncSchema.EncryptedSecret.recordName(for: identifier),
            recordType: SyncSchema.EncryptedSecret.recordType,
            fields: [
                "identifier": (secret.identifier, "STRING"),
                "ciphertext": (secret.ciphertext.base64EncodedString(), "BYTES"),
                "nonce": (secret.nonce.base64EncodedString(), "BYTES"),
                "tag": (secret.tag.base64EncodedString(), "BYTES"),
                "updatedAt": (CloudKitWebFixture.milliseconds(secret.updatedAt), "TIMESTAMP"),
                "isDeleted": (deleted ? 1 : 0, "INT64")
            ]
        )
    }

    func testThePassphraseUnlocksAndOpensEverySyncedKey() async throws {
        let key = try seedMetadata()
        try seedSecret("openai.apiKey", value: "synthetic-openai", key: key)
        try seedSecret("deepgram.apiKey", value: "synthetic-deepgram", key: key)
        try seedSecret("gladia.apiKey", value: "", key: key, deleted: true)

        let unlocked = try await CloudKitWebKeySync.unlock(
            passphrase: "  \(passphrase)\n", client: client, consent: consent, envelope: envelope
        )
        XCTAssertEqual(unlocked, key)
        let snapshot = try await CloudKitWebKeySync.read(
            key: unlocked, client: client, consent: consent, envelope: envelope
        )

        XCTAssertEqual(snapshot.secrets.map(\.identifier), ["deepgram.apiKey", "gladia.apiKey", "openai.apiKey"])
        XCTAssertEqual(snapshot.secrets.first { $0.identifier == "openai.apiKey" }?.value, "synthetic-openai")
        XCTAssertEqual(snapshot.secrets.first { $0.identifier == "gladia.apiKey" }?.isDeleted, true)
        XCTAssertTrue(snapshot.unreadableIdentifiers.isEmpty)
        XCTAssertEqual(server.requestLog.filter { $0.hasSuffix("records/modify") }.count, 0, "Key import never writes")
    }

    func testAWrongPassphraseIsRejectedBeforeAnyKeyIsRead() async throws {
        _ = try seedMetadata()
        do {
            _ = try await CloudKitWebKeySync.unlock(
                passphrase: "incorrect horse battery", client: client, consent: consent, envelope: envelope
            )
            XCTFail("A wrong passphrase must not unlock")
        } catch {
            XCTAssertEqual(error as? CloudKitKeySyncError, .incorrectPassphrase)
        }
    }

    func testAKeyFromBeforeAPassphraseResetAsksForThePassphraseAgain() async throws {
        let oldKey = try seedMetadata()
        _ = try seedMetadata(passphrase: "a completely new passphrase")
        do {
            _ = try await CloudKitWebKeySync.read(key: oldKey, client: client, consent: consent, envelope: envelope)
            XCTFail("A stale key must not read")
        } catch {
            XCTAssertEqual(error as? CloudKitKeySyncError, .incorrectPassphrase)
        }
    }

    func testAnAccountWithoutKeySyncSaysSo() async throws {
        do {
            _ = try await CloudKitWebKeySync.unlock(
                passphrase: passphrase, client: client, consent: consent, envelope: envelope
            )
            XCTFail("No metadata means no synced keys")
        } catch {
            XCTAssertEqual(error as? CloudKitWebKeySyncError, .noSyncedKeys)
        }
    }

    func testARecordNamedForOneProviderCannotDeliverAnothersKey() async throws {
        let key = try seedMetadata()
        try seedSecret("openai.apiKey", value: "misfiled", key: key, storedIdentifier: "deepgram.apiKey")

        let snapshot = try await CloudKitWebKeySync.read(key: key, client: client, consent: consent, envelope: envelope)

        XCTAssertTrue(snapshot.secrets.isEmpty)
        XCTAssertEqual(snapshot.unreadableIdentifiers, ["openai.apiKey"])
    }

    func testKeysAreNotReadWithoutTheirOwnConsent() async throws {
        do {
            _ = try await CloudKitWebKeySync.unlock(
                passphrase: passphrase,
                client: client,
                consent: CloudKitWebSyncConsent(enabledFeatures: [.history]),
                envelope: envelope
            )
            XCTFail("History consent must not cover API keys")
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesError, .consentRequired(.apiKeys))
        }
    }

    func testTheSyncableIdentifiersAreTheCanonicalCatalogueEntries() {
        // Every synced identifier is a credential some shared catalogue route
        // actually asks for, so an imported key always has somewhere to go.
        for identifier in SyncSchema.EncryptedSecret.syncableIdentifiers {
            XCTAssertTrue(identifier.hasSuffix(".apiKey"), identifier)
            XCTAssertEqual(
                SyncSchema.EncryptedSecret.identifier(
                    fromRecordName: SyncSchema.EncryptedSecret.recordName(for: identifier)
                ),
                identifier
            )
        }
    }
}

/// Deterministic, keyed stand-in primitives. Not encryption: it only lets the
/// envelope's control flow (verifier, per-record open, key mismatch) run
/// without a platform cryptography library.
struct ToyEnvelopeCryptography: SyncEnvelopeCryptography {
    func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyByteCount: Int) throws -> Data {
        var key = [UInt8](repeating: 0x11, count: keyByteCount)
        for (index, byte) in (password + salt).enumerated() {
            key[index % keyByteCount] = key[index % keyByteCount] &* 31 &+ byte
        }
        return Data(key)
    }

    func sealAESGCM(_ plaintext: Data, key: Data) throws -> SealedEnvelopePayload {
        let nonce = try randomBytes(count: 12)
        let ciphertext = Data(plaintext.enumerated().map {
            $0.element ^ key[$0.offset % key.count] ^ nonce[$0.offset % 12]
        })
        return SealedEnvelopePayload(nonce: nonce, ciphertext: ciphertext, tag: tag(ciphertext, key: key, nonce: nonce))
    }

    func openAESGCM(_ sealed: SealedEnvelopePayload, key: Data) throws -> Data {
        guard tag(sealed.ciphertext, key: key, nonce: sealed.nonce) == sealed.tag else {
            throw CloudKitKeySyncError.encryptionFailed
        }
        return Data(sealed.ciphertext.enumerated().map {
            $0.element ^ key[$0.offset % key.count] ^ sealed.nonce[$0.offset % 12]
        })
    }

    func randomBytes(count: Int) throws -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func tag(_ ciphertext: Data, key: Data, nonce: Data) -> Data {
        var tag = [UInt8](repeating: 0x5C, count: 16)
        for (index, byte) in (key + nonce + ciphertext).enumerated() {
            tag[index % 16] = tag[index % 16] &* 131 &+ byte
        }
        return Data(tag)
    }
}
