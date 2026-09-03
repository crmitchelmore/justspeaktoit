import Foundation
import Security
import XCTest

@testable import SpeakCore

/// Scripted permission checker: each keychain access consumes one decision.
private final class ScriptedPermissions: KeychainPermissionsChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var decisions: [Bool]

    init(decisions: [Bool]) {
        self.decisions = decisions
    }

    func ensureKeychainAccess(forService service: String) async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return decisions.isEmpty ? true : decisions.removeFirst()
    }
}

/// Transactional configuration import (issue #699): parity with the canonical
/// credential catalogue, all-or-nothing application, rollback reporting, and
/// idempotent retry.
final class ConfigTransferImportTests: XCTestCase { // swiftlint:disable:this type_body_length
    private let manager = ConfigTransferManager(pbkdf2Iterations: 1_000)
    private var service: String!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        service = "com.justspeaktoit.tests.transfer.\(UUID().uuidString.prefix(8))"
        defaultsSuite = "com.justspeaktoit.tests.transfer.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() {
        for account in [
            "speak-app-secrets",
            "speak-app-secrets.v2",
            "speak-app-secrets.unsupported-backup"
        ] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        service = nil
        defaultsSuite = nil
        defaults = nil
        super.tearDown()
    }

    private func makeStorage(decisions: [Bool] = []) -> SecureStorage {
        SecureStorage(
            configuration: SecureStorageConfiguration(service: service),
            permissionsChecker: ScriptedPermissions(decisions: decisions)
        )
    }

    // MARK: - Catalogue parity

    func testTransferableSecretIdentifiers_matchTheCanonicalCredentialCatalogue() {
        // Adding a provider to any catalogue must fail this test until its
        // transfer capability is defined in transferableSecretIdentifiers.
        XCTAssertEqual(
            ConfigTransferManager.transferableSecretIdentifiers.sorted(),
            ModelCredentialResolver.allKnownAPIKeyIdentifiers.sorted()
        )
        XCTAssertEqual(
            ConfigTransferManager.transferableSecretIdentifiers,
            ConfigTransferManager.transferableSecretIdentifiers.sorted(),
            "keep the policy list sorted so diffs stay reviewable"
        )
    }

    func testPreviouslyOmittedProviders_areNowTransferable() {
        let identifiers = Set(ConfigTransferManager.transferableSecretIdentifiers)
        for required in [
            "assemblyai.apiKey", "cartesia.apiKey", "gladia.apiKey", "google.apiKey", "groq.apiKey",
            "mistral.apiKey", "modulate.apiKey", "revai.apiKey", "soniox.apiKey",
            "speechmatics.apiKey", "xai.apiKey"
        ] {
            XCTAssertTrue(identifiers.contains(required), "\(required) must transfer")
        }
    }

    /// Keywords are one list under one key on both platforms (issue #849), so
    /// a device-to-device transfer carries them verbatim.
    func testTranscriptionKeywords_areATransferableSetting() {
        XCTAssertTrue(
            ConfigTransferManager.transferableSettingKeys.contains(
                ConfigTransferManager.transcriptionKeywordsKey))
        XCTAssertEqual(ConfigTransferManager.transcriptionKeywordsKey, "transcriptionKeywords")
    }

    func testGatherSettings_carriesTheKeywordListButNeverAnEmptyOne() {
        defaults.set("deepgram/nova-3-streaming", forKey: "selectedModel")

        XCTAssertNil(manager.gatherSettings(defaults: defaults)["transcriptionKeywords"])

        defaults.set("JustSpeakToIt, Muse", forKey: "transcriptionKeywords")
        let settings = manager.gatherSettings(defaults: defaults)

        XCTAssertEqual(settings["transcriptionKeywords"], "JustSpeakToIt, Muse")
        XCTAssertEqual(settings["selectedModel"], "deepgram/nova-3-streaming")
    }

    func testApplyImport_writesTheKeywordListUnderTheSharedKey() async throws {
        let payload = ConfigTransferPayload(
            secrets: [:],
            settings: ["transcriptionKeywords": "JustSpeakToIt, Muse"]
        )

        try await manager.applyImport(payload: payload, storage: makeStorage(), defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "transcriptionKeywords"), "JustSpeakToIt, Muse")
    }

    // MARK: - Transactional apply

    func testApplyImport_appliesSecretsAndSettings() async throws {
        let storage = makeStorage()
        let payload = ConfigTransferPayload(
            secrets: ["deepgram.apiKey": "dg-new", "gladia.apiKey": "gl-new"],
            settings: ["selectedModel": "deepgram/nova-3-streaming"]
        )

        try await manager.applyImport(payload: payload, storage: storage, defaults: defaults)

        let deepgram = try await storage.secret(identifier: "deepgram.apiKey")
        let gladia = try await storage.secret(identifier: "gladia.apiKey")
        XCTAssertEqual(deepgram, "dg-new")
        XCTAssertEqual(gladia, "gl-new")
        XCTAssertEqual(defaults.string(forKey: "selectedModel"), "deepgram/nova-3-streaming")
    }

    func testApplyImport_failedWrite_rollsBackEverySecretAndSkipsSettings() async throws {
        let seed = makeStorage()
        try await seed.storeSecret("dg-old", identifier: "deepgram.apiKey")

        // Decisions: load, store deepgram (ok), store gladia (denied),
        // rollback of deepgram (ok).
        let storage = makeStorage(decisions: [true, true, false, true])
        let payload = ConfigTransferPayload(
            secrets: ["deepgram.apiKey": "dg-new", "gladia.apiKey": "gl-new"],
            settings: ["selectedModel": "changed"]
        )

        do {
            try await manager.applyImport(payload: payload, storage: storage, defaults: defaults)
            XCTFail("Expected the denied write to fail the import")
        } catch SecureStorageError.permissionDenied {
            // Expected: the original failure surfaces once rollback succeeded.
        }

        let verify = makeStorage()
        let deepgram = try await verify.secret(identifier: "deepgram.apiKey")
        XCTAssertEqual(deepgram, "dg-old", "the replaced credential must be restored")
        let hasGladia = await verify.hasSecret(identifier: "gladia.apiKey")
        XCTAssertFalse(hasGladia)
        XCTAssertNil(defaults.string(forKey: "selectedModel"), "settings must not partially apply")
    }

    func testApplyImport_rollbackFailure_reportsTheStrandedIdentifiers() async throws {
        // Decisions: load, store deepgram (ok), store gladia (denied),
        // rollback of deepgram (denied too).
        let storage = makeStorage(decisions: [true, true, false, false])
        let payload = ConfigTransferPayload(
            secrets: ["deepgram.apiKey": "dg-new", "gladia.apiKey": "gl-new"],
            settings: [:]
        )

        do {
            try await manager.applyImport(payload: payload, storage: storage, defaults: defaults)
            XCTFail("Expected rollbackFailed")
        } catch let error as ConfigTransferError {
            XCTAssertEqual(error, .rollbackFailed(identifiers: ["deepgram.apiKey"]))
        }
    }

    func testApplyImport_retryAfterFailure_isIdempotentAndComplete() async throws {
        let seed = makeStorage()
        try await seed.storeSecret("dg-old", identifier: "deepgram.apiKey")

        let failing = makeStorage(decisions: [true, true, false, true])
        let payload = ConfigTransferPayload(
            secrets: ["deepgram.apiKey": "dg-new", "gladia.apiKey": "gl-new"],
            settings: ["selectedModel": "deepgram/nova-3-streaming"]
        )
        do {
            try await manager.applyImport(payload: payload, storage: failing, defaults: defaults)
            XCTFail("Expected failure")
        } catch SecureStorageError.permissionDenied {
            // Expected.
        }

        // Retrying the identical import must converge on the full new state.
        let retry = makeStorage()
        try await manager.applyImport(payload: payload, storage: retry, defaults: defaults)

        let deepgram = try await retry.secret(identifier: "deepgram.apiKey")
        let gladia = try await retry.secret(identifier: "gladia.apiKey")
        XCTAssertEqual(deepgram, "dg-new")
        XCTAssertEqual(gladia, "gl-new")
        XCTAssertEqual(defaults.string(forKey: "selectedModel"), "deepgram/nova-3-streaming")
    }

    // MARK: - Bounded policy

    func testApplyImport_unknownSecretIdentifier_isRefusedBeforeAnyWrite() async throws {
        let storage = makeStorage()
        let payload = ConfigTransferPayload(
            secrets: ["custom-provider.apiKey": "x", "deepgram.apiKey": "dg"],
            settings: [:]
        )

        do {
            try await manager.applyImport(payload: payload, storage: storage, defaults: defaults)
            XCTFail("Expected unknownSecretIdentifier")
        } catch let error as ConfigTransferError {
            XCTAssertEqual(error, .unknownSecretIdentifier("custom-provider.apiKey"))
        }

        let identifiers = await storage.knownIdentifiers()
        XCTAssertEqual(identifiers, [], "nothing may be written for a refused payload")
    }

    func testApplyImport_mapsSelectedModelToThePlatformLiveModelKey() async throws {
        let storage = makeStorage()
        let payload = ConfigTransferPayload(
            secrets: [:],
            settings: ["selectedModel": "deepgram/nova-3-streaming"]
        )

        try await manager.applyImport(
            payload: payload,
            storage: storage,
            defaults: defaults,
            liveModelDefaultsKey: "liveTranscriptionModel"
        )

        XCTAssertEqual(
            defaults.string(forKey: "liveTranscriptionModel"), "deepgram/nova-3-streaming",
            "Import must reverse the export-time key normalisation for the importing platform"
        )
        XCTAssertNil(defaults.string(forKey: "selectedModel"))
    }

    func testApplyImport_emptySecret_isRefusedBeforeAnyWrite() async throws {
        let storage = makeStorage()
        try await storage.storeSecret("dg-working", identifier: "deepgram.apiKey")
        let payload = ConfigTransferPayload(
            secrets: ["deepgram.apiKey": "", "gladia.apiKey": "gl-new"],
            settings: [:]
        )

        do {
            try await manager.applyImport(payload: payload, storage: storage, defaults: defaults)
            XCTFail("Expected emptySecretValue")
        } catch let error as ConfigTransferError {
            XCTAssertEqual(error, .emptySecretValue("deepgram.apiKey"))
        }

        let deepgram = try await storage.secret(identifier: "deepgram.apiKey")
        XCTAssertEqual(deepgram, "dg-working", "An empty imported value must not clobber a working credential")
        let identifiers = await storage.knownIdentifiers()
        XCTAssertFalse(identifiers.contains("gladia.apiKey"), "Nothing is written when validation fails")
    }

    func testApplyImport_emptySetting_isRefused() async throws {
        let storage = makeStorage()
        let payload = ConfigTransferPayload(secrets: [:], settings: ["selectedModel": ""])

        do {
            try await manager.applyImport(payload: payload, storage: storage, defaults: defaults)
            XCTFail("Expected emptySettingValue")
        } catch let error as ConfigTransferError {
            XCTAssertEqual(error, .emptySettingValue("selectedModel"))
        }
        XCTAssertNil(defaults.string(forKey: "selectedModel"))
    }

    func testApplyImport_unknownSettingKey_isRefusedBeforeAnyWrite() async throws {
        let storage = makeStorage()
        let payload = ConfigTransferPayload(
            secrets: ["deepgram.apiKey": "dg"],
            settings: ["arbitraryDefaultsKey": "boom"]
        )

        do {
            try await manager.applyImport(payload: payload, storage: storage, defaults: defaults)
            XCTFail("Expected unknownSettingKey")
        } catch let error as ConfigTransferError {
            XCTAssertEqual(error, .unknownSettingKey("arbitraryDefaultsKey"))
        }

        let identifiers = await storage.knownIdentifiers()
        XCTAssertEqual(identifiers, [])
        XCTAssertNil(defaults.string(forKey: "arbitraryDefaultsKey"))
    }
    // MARK: - QR payload budget (issue #699)

    private let code = "A1B2C3D4"

    /// Deterministic high-entropy stand-in for a real API key: repeated
    /// characters would understate the QR budget.
    private func syntheticKey(seed: Int, length: Int = 72) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var state = UInt64(seed) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var characters: [Character] = []
        for _ in 0..<length {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            characters.append(alphabet[Int(state >> 33) % alphabet.count])
        }
        return String(characters)
    }

    func testGeneratedPayload_forAFullKeySet_stillFitsInAQRCode() throws {
        // The encrypted envelope is markedly larger than the format it replaces,
        // so guard the worst realistic case: every transferable key populated
        // with realistic-entropy values (issue #699 widened the catalogue).
        let secrets = Dictionary(
            uniqueKeysWithValues: ConfigTransferManager.transferableSecretIdentifiers.enumerated().map {
                ($1, syntheticKey(seed: $0))
            }
        )
        let transfer = try manager.makeTransfer(
            secrets: secrets,
            settings: ["selectedModel": "deepgram/nova-3-streaming"]
        )
        XCTAssertNotNil(manager.makeQRCodeImage(payload: transfer.payload), "Payload too large to encode as a QR code")
        XCTAssertEqual(try manager.decodePayload(transfer.payload, code: transfer.code).secrets.count, secrets.count)
    }

    func testGeneratedPayload_smallSet_keepsTheBackwardCompatibleBase64Shape() throws {
        let encoded = try manager.generatePayload(
            secrets: ["deepgram.apiKey": syntheticKey(seed: 99)],
            settings: [:],
            code: code
        )
        XCTAssertNotNil(Data(base64Encoded: encoded), "small payloads must stay importable by older builds")
        XCTAssertEqual(try manager.format(of: encoded), .encrypted)
    }

    func testGeneratedPayload_oversizedSet_roundTripsThroughTheEnvelopeJSONShape() throws {
        let secrets = Dictionary(
            uniqueKeysWithValues: ConfigTransferManager.transferableSecretIdentifiers.enumerated().map {
                ($1, syntheticKey(seed: 1_000 + $0, length: 90))
            }
        )
        let encoded = try manager.generatePayload(secrets: secrets, settings: [:], code: code)
        XCTAssertTrue(encoded.hasPrefix("{"), "oversized payloads carry the envelope JSON directly")
        XCTAssertEqual(try manager.format(of: encoded), .encrypted)
        let decoded = try manager.decodePayload(encoded, code: code)
        XCTAssertEqual(decoded.secrets, secrets)
        XCTAssertNotNil(manager.makeQRCodeImage(payload: encoded))
    }
}
