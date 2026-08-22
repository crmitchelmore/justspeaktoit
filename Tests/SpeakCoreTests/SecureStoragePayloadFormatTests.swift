import Foundation
import Security
import XCTest

@testable import SpeakCore

/// Covers the aggregate keychain payload format (issue #623): values containing the
/// structural characters `;` and `=` must round-trip intact, and legacy unencoded
/// payloads must keep loading transparently.
final class SecureStoragePayloadFormatTests: XCTestCase {

    // MARK: - Format round-trips (no keychain)

    func testValueContainingSeparator_roundTrips() {
        assertRoundTrips(["openai": "sk-abc;def", "deepgram": "plain"])
    }

    func testValueContainingEquals_roundTrips() {
        assertRoundTrips(["openai": "a=b=c", "other": "x"])
    }

    func testValueContainingPercent_roundTrips() {
        assertRoundTrips(["openai": "100%;=%3B-not-a-separator"])
    }

    func testUnicodeValue_roundTrips() {
        assertRoundTrips(["openai": "clé-秘密-🔑;=", "grüße": "naïve"])
    }

    func testEmptyValue_roundTrips() {
        assertRoundTrips(["cleared": "", "kept": "value"])
    }

    func testWhitespaceInValue_roundTripsExactly() {
        assertRoundTrips(["openai": "  padded key \n"])
    }

    func testKeyContainingStructuralCharacters_roundTrips() {
        assertRoundTrips(["odd;key=name": "value"])
    }

    func testManyEntries_allSurvive() {
        let cache = (0..<20).reduce(into: [String: String]()) { partialResult, index in
            partialResult["provider-\(index)"] = "secret;=%\(index)"
        }
        assertRoundTrips(cache)
    }

    func testSerializedPayload_carriesVersionPrefix() {
        let payload = SecureStorage.serialize(cache: ["a-key": "value"])
        XCTAssertTrue(payload.hasPrefix(SecureStorage.payloadVersionPrefix))
    }

    func testEmptyCache_serializesToEmptyString() {
        // Must stay empty (not a bare version prefix) so the keychain item is deleted
        // when the last secret is removed.
        XCTAssertEqual(SecureStorage.serialize(cache: [:]), "")
    }

    // MARK: - Legacy payload migration

    func testLegacyPayload_parsesTransparently() {
        let parsed = SecureStorage.parse(payload: "deepgram=dg-key;openai=sk-123")
        XCTAssertEqual(parsed, ["deepgram": "dg-key", "openai": "sk-123"])
    }

    func testLegacyPayload_valueContainingEquals_isPreserved() {
        let parsed = SecureStorage.parse(payload: "openai=sk=with=equals")
        XCTAssertEqual(parsed, ["openai": "sk=with=equals"])
    }

    func testLegacyPayload_identifierWithVersionPrefix_parsesTransparently() {
        let parsed = SecureStorage.parse(payload: "v2:openai=sk-123")
        XCTAssertEqual(parsed, ["v2:openai": "sk-123"])
    }

    func testLegacyPayload_reserializesInVersionedFormat() {
        let parsed = SecureStorage.parse(payload: "deepgram=dg-key;openai=sk-123")
        let rewritten = SecureStorage.serialize(cache: parsed)
        XCTAssertTrue(rewritten.hasPrefix(SecureStorage.payloadVersionPrefix))
        XCTAssertEqual(SecureStorage.parse(payload: rewritten), parsed)
    }

    // MARK: - Keychain round-trip (issue #623 repro)

    func testSecretWithSemicolon_survivesReloadFromKeychain() async throws {
        let service = uniqueService()
        defer { deleteKeychainItem(service: service) }

        let storage = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        try await storage.storeSecret("sk-first;half", identifier: "openai")
        try await storage.storeSecret("dg-second", identifier: "deepgram")

        // A fresh instance re-parses the persisted payload from scratch.
        let reloaded = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let first = try await reloaded.secret(identifier: "openai")
        let second = try await reloaded.secret(identifier: "deepgram")
        XCTAssertEqual(first, "sk-first;half")
        XCTAssertEqual(second, "dg-second")

        let identifiers = await reloaded.knownIdentifiers()
        XCTAssertEqual(identifiers, ["deepgram", "openai"])
    }

    func testLegacyKeychainPayload_isReadAndPartitionedOnNextSave() async throws {
        let service = uniqueService()
        defer { deleteKeychainItem(service: service) }

        try addKeychainPayload("deepgram=dg-key;openai=sk-123", service: service)

        // Legacy payload loads transparently.
        let storage = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let legacyValue = try await storage.secret(identifier: "openai")
        XCTAssertEqual(legacyValue, "sk-123")

        // The next save keeps the master item in the legacy interchange
        // format (issue #672) and moves the unrepresentable value to the
        // overflow item, so a rolled-back binary still reads its secrets.
        try await storage.storeSecret("el;evenlabs=key", identifier: "elevenlabs")

        let compatibilityRecord = try XCTUnwrap(readKeychainPayload(service: service))
        XCTAssertNil(SecureStorage.versionMarker(of: compatibilityRecord))
        XCTAssertEqual(compatibilityRecord, "deepgram=dg-key;openai=sk-123")
        let overflowPayload = try XCTUnwrap(
            readKeychainPayload(service: service, account: "\(aggregateAccount).v2")
        )
        XCTAssertTrue(overflowPayload.hasPrefix(SecureStorage.payloadVersionPrefix))

        let reloaded = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let migrated = try await reloaded.secret(identifier: "deepgram")
        let untouched = try await reloaded.secret(identifier: "openai")
        let added = try await reloaded.secret(identifier: "elevenlabs")
        XCTAssertEqual(migrated, "dg-key")
        XCTAssertEqual(untouched, "sk-123")
        XCTAssertEqual(added, "el;evenlabs=key")
    }

    // MARK: - Mixed-version compatibility contract (issue #672)

    /// The exact parser shipped before payload versioning existed (#631):
    /// raw `key=value;` pairs, no version awareness, no decoding. What this
    /// reads is what a rolled-back binary sees.
    private func parseWithLastLegacyParser(_ payload: String) -> [String: String] {
        payload
            .split(separator: ";")
            .reduce(into: [String: String]()) { partialResult, item in
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let components = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let keyComponent = components.first else { return }
                partialResult[String(keyComponent)] =
                    components.count > 1 ? String(components[1]) : ""
            }
    }

    func testSave_writesACompatibilityRecordTheLastLegacyParserReadsCorrectly() async throws {
        let service = uniqueService()
        defer { deleteKeychainItem(service: service) }

        let storage = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        try await storage.storeSecret("sk-plain-123", identifier: "openai")
        try await storage.storeSecret("value=with=equals", identifier: "deepgram")
        try await storage.storeSecret("semi;colon-secret", identifier: "gladia")

        let compatibilityRecord = try XCTUnwrap(readKeychainPayload(service: service))
        let legacyView = parseWithLastLegacyParser(compatibilityRecord)

        // Representable values round-trip verbatim for the legacy parser…
        XCTAssertEqual(legacyView["openai"], "sk-plain-123")
        XCTAssertEqual(legacyView["deepgram"], "value=with=equals")
        // …no marker identifier is invented…
        XCTAssertNil(legacyView["v2:"])
        // …and a delimiter-bearing value is absent rather than served as a
        // percent-encoded stand-in the legacy binary would use as an API key.
        XCTAssertNil(legacyView["gladia"])
        XCTAssertFalse(compatibilityRecord.contains("%3B"))
        XCTAssertFalse(compatibilityRecord.contains("semi"))

        // The current build still reads everything.
        let reloaded = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let tricky = try await reloaded.secret(identifier: "gladia")
        XCTAssertEqual(tricky, "semi;colon-secret")
    }

    func testUpgradeRollbackUpgrade_preservesCredentialsAndRegistryIdentifiers() async throws {
        let service = uniqueService()
        defer { deleteKeychainItem(service: service) }

        // Upgrade: the current build stores one representable and one
        // overflow-only secret.
        let storage = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        try await storage.storeSecret("sk-1", identifier: "openai")
        try await storage.storeSecret("semi;colon", identifier: "gladia")

        // Rollback: a legacy binary reads the compatibility record, edits its
        // view (it only ever saw the representable entries), and rewrites the
        // master item in the legacy format — exactly what its save path does.
        let compatibilityRecord = try XCTUnwrap(readKeychainPayload(service: service))
        var legacyView = parseWithLastLegacyParser(compatibilityRecord)
        XCTAssertEqual(legacyView, ["openai": "sk-1"])
        legacyView["openai"] = "sk-2-rotated"
        let legacyRewrite = legacyView.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        deleteKeychainItem(service: service, account: aggregateAccount)
        try addKeychainPayload(legacyRewrite, service: service)

        // Upgrade again: the legacy edit wins for the shared key, and the
        // overflow-only secret the legacy build never saw survives.
        let upgraded = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let rotated = try await upgraded.secret(identifier: "openai")
        let preserved = try await upgraded.secret(identifier: "gladia")
        XCTAssertEqual(rotated, "sk-2-rotated")
        XCTAssertEqual(preserved, "semi;colon")
        let identifiers = await upgraded.knownIdentifiers()
        XCTAssertEqual(identifiers, ["gladia", "openai"])
    }

    func testUnknownNewerVersionPayload_isBackedUpAndNeverParsedAsLegacy() async throws {
        let service = uniqueService()
        defer { deleteKeychainItem(service: service) }

        let futurePayload = "v3:;opaque-future-format"
        try addKeychainPayload(futurePayload, service: service)

        let storage = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let identifiers = await storage.knownIdentifiers()
        // The marker must not be invented as an identifier.
        XCTAssertEqual(identifiers, [])

        // A save may proceed, but only after the unreadable record was
        // preserved byte-for-byte.
        try await storage.storeSecret("dg-key", identifier: "deepgram")
        let backup = readKeychainPayload(
            service: service,
            account: "\(aggregateAccount).unsupported-backup"
        )
        XCTAssertEqual(backup, futurePayload)

        let reloaded = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let stored = try await reloaded.secret(identifier: "deepgram")
        XCTAssertEqual(stored, "dg-key")
    }

    func testEmptyIdentifier_failsWithoutKeychainWriteOrNotification() async throws {
        let service = uniqueService()
        defer { deleteKeychainItem(service: service) }

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SecureStorage.didChangeSecretNotification,
            object: nil,
            queue: nil
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let storage = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        for identifier in ["", "   ", "\n"] {
            do {
                try await storage.storeSecret("value", identifier: identifier)
                XCTFail("Expected emptyIdentifier for \(identifier.debugDescription)")
            } catch let error as SecureStorageError {
                XCTAssertEqual(error, .emptyIdentifier)
            }
            do {
                _ = try await storage.secret(identifier: identifier)
                XCTFail("Expected emptyIdentifier for \(identifier.debugDescription)")
            } catch let error as SecureStorageError {
                XCTAssertEqual(error, .emptyIdentifier)
            }
            do {
                try await storage.removeSecret(identifier: identifier)
                XCTFail("Expected emptyIdentifier for \(identifier.debugDescription)")
            } catch let error as SecureStorageError {
                XCTAssertEqual(error, .emptyIdentifier)
            }
            let has = await storage.hasSecret(identifier: identifier)
            XCTAssertFalse(has)
        }

        XCTAssertNil(readKeychainPayload(service: service))
        XCTAssertNil(readKeychainPayload(service: service, account: "\(aggregateAccount).v2"))
        XCTAssertEqual(notificationCount, 0)
        let identifiers = await storage.knownIdentifiers()
        XCTAssertEqual(identifiers, [])
    }

    func testPayloadVersionMigrationTable() {
        // Extend this table whenever a payload version is added (issue #672);
        // an in-place format change must fail here first.
        XCTAssertEqual(SecureStorage.currentPayloadVersion, 2)
        XCTAssertEqual(SecureStorage.payloadVersionPrefix, "v2:;")

        // Legacy (unversioned) payloads parse as secrets.
        XCTAssertEqual(
            SecureStorage.parsePayload("a=1;b=2"),
            .secrets(["a": "1", "b": "2"])
        )
        // A legacy identifier that merely resembles a marker stays legacy.
        XCTAssertEqual(
            SecureStorage.parsePayload("v2:openai=sk-123"),
            .secrets(["v2:openai": "sk-123"])
        )
        // The current version parses its encoded body.
        XCTAssertEqual(
            SecureStorage.parsePayload("v2:;a=1%3B2"),
            .secrets(["a": "1;2"])
        )
        // Newer versions are explicit refusals, never legacy data.
        XCTAssertEqual(SecureStorage.parsePayload("v3:;anything"), .unsupportedVersion("v3"))
        XCTAssertEqual(SecureStorage.parsePayload("v10:;x=y"), .unsupportedVersion("v10"))
    }

    func testLegacyKeychainPayload_identifierWithVersionPrefix_survivesReloadAndSave() async throws {
        let service = uniqueService()
        defer { deleteKeychainItem(service: service) }

        try addKeychainPayload("v2:openai=sk-123", service: service)

        let storage = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let legacyValue = try await storage.secret(identifier: "v2:openai")
        XCTAssertEqual(legacyValue, "sk-123")

        try await storage.storeSecret("dg-key", identifier: "deepgram")

        let reloaded = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let preserved = try await reloaded.secret(identifier: "v2:openai")
        XCTAssertEqual(preserved, "sk-123")
        let identifiers = await reloaded.knownIdentifiers()
        XCTAssertEqual(identifiers, ["deepgram", "v2:openai"])
    }

    // MARK: - Helpers

    private func assertRoundTrips(
        _ cache: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let payload = SecureStorage.serialize(cache: cache)
        let parsed = SecureStorage.parse(payload: payload)
        XCTAssertEqual(parsed, cache, file: file, line: line)
    }

    private func uniqueService() -> String {
        "com.github.speakapp.tests.payload.\(UUID().uuidString.prefix(8))"
    }
}

private let aggregateAccount = "speak-app-secrets"

private func addKeychainPayload(
    _ payload: String,
    service: String,
    account: String = aggregateAccount
) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: Data(payload.utf8)
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw SecureStorageError.unexpectedStatus(status)
    }
}

private func readKeychainPayload(service: String, account: String = aggregateAccount) -> String? {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ]
    query[kSecReturnData as String] = true

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

private func deleteKeychainItem(service: String, account: String? = nil) {
    let accounts = account.map { [$0] } ?? [
        aggregateAccount,
        "\(aggregateAccount).v2",
        "\(aggregateAccount).unsupported-backup"
    ]
    for accountName in accounts {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName
        ]
        SecItemDelete(query as CFDictionary)
    }
}
