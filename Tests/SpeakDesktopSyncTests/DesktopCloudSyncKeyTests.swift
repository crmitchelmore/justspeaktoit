import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync
import SpeakSync
import SpeakTestSupport
import XCTest

final class DesktopCloudSyncKeyTests: DesktopCloudSyncTestCase {
    // MARK: - API keys

    private func seedMacKeys(passphrase: String, keys: [String: String], deleted: [String] = []) throws {
        let envelope = EncryptedSecretEnvelope(cryptography: ToyCryptography())
        let created = try envelope.makeMetadata(passphrase: passphrase)
        let name = "api-key-sync-metadata"
        server.seedRecord(zone: zone, recordName: name, recordType: "EncryptedSecretMetadata", fields: [
            "salt": (created.metadata.salt.base64EncodedString(), "BYTES"),
            "verifierNonce": (created.metadata.verifierNonce.base64EncodedString(), "BYTES"),
            "verifierCiphertext": (created.metadata.verifierCiphertext.base64EncodedString(), "BYTES"),
            "verifierTag": (created.metadata.verifierTag.base64EncodedString(), "BYTES"),
            "updatedAt": (milliseconds(fixtureDate(0)), "TIMESTAMP")
        ])
        try seedSecrets(keys, deleted: deleted, key: created.key, at: fixtureDate(100))
    }

    private func seedSecrets(_ keys: [String: String], deleted: [String] = [], key: Data? = nil, at date: Date) throws {
        let envelope = EncryptedSecretEnvelope(cryptography: ToyCryptography())
        let stored = try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey)
        let key = try key ?? XCTUnwrap(stored.flatMap { Data(base64Encoded: $0) })
        let entries = keys.map { ($0.key, $0.value, false) } + deleted.map { ($0, "", true) }
        for (identifier, value, isDeleted) in entries {
            let secret = try envelope.seal(
                identifier: identifier, value: value, updatedAt: date, key: key, isDeleted: isDeleted
            )
            server.seedRecord(zone: zone, recordName: SyncSchema.EncryptedSecret.recordName(for: identifier),
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

    func testKeyImportIsOptInAndKeepsOnlyTheDerivedKey() async throws {
        let passphrase = "correct horse battery staple"
        try seedMacKeys(
            passphrase: passphrase,
            keys: ["openai.apiKey": "synthetic-openai", "xai.apiKey": "synthetic-xai"]
        )
        let (service, _) = try await signedInService()

        _ = await service.sync()
        XCTAssertNil(try vault.readCredential("openai.apiKey"), "Nothing is imported until the user opts in")

        let report = try await service.enableKeyImport(passphrase: passphrase)

        XCTAssertEqual(report.importedKeys.sorted(), ["openai.apiKey", "xai.apiKey"])
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "synthetic-openai")
        XCTAssertNotNil(try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey))
        let status = await service.status()
        XCTAssertTrue(status.apiKeyImportEnabled)
    }

    func testAWrongPassphraseImportsNothing() async throws {
        try seedMacKeys(passphrase: "correct horse battery staple", keys: ["openai.apiKey": "synthetic-openai"])
        let (service, _) = try await signedInService()

        do {
            _ = try await service.enableKeyImport(passphrase: "wrong horse battery staple")
            XCTFail("A wrong passphrase must not import")
        } catch {
            XCTAssertEqual(error as? CloudKitKeySyncError, .incorrectPassphrase)
        }
        XCTAssertNil(try vault.readCredential("openai.apiKey"))
        XCTAssertNil(try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey))
    }

    func testLaterMacChangesApplyButAHandSavedKeySurvivesARemoteDeletion() async throws {
        let passphrase = "correct horse battery staple"
        try seedMacKeys(passphrase: passphrase, keys: ["openai.apiKey": "first", "deepgram.apiKey": "dg"])
        let (service, _) = try await signedInService()
        _ = try await service.enableKeyImport(passphrase: passphrase)

        try vault.writeCredential("typed on windows", name: "deepgram.apiKey")
        await service.noteManualKeySave(identifier: "deepgram.apiKey")
        try seedSecrets(["openai.apiKey": "second"], deleted: ["deepgram.apiKey"], at: fixtureDate(900))
        let report = await service.sync()

        XCTAssertNil(report.error)
        XCTAssertEqual(try vault.readCredential("openai.apiKey"), "second")
        XCTAssertEqual(try vault.readCredential("deepgram.apiKey"), "typed on windows")
        XCTAssertEqual(report.importedKeys, ["openai.apiKey"])
        XCTAssertTrue(report.removedKeys.isEmpty)
    }
}
