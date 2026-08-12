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

    func testLegacyKeychainPayload_isReadAndUpgradedOnNextSave() async throws {
        let service = uniqueService()
        defer { deleteKeychainItem(service: service) }

        try addKeychainPayload("deepgram=dg-key;openai=sk-123", service: service)

        // Legacy payload loads transparently.
        let storage = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let legacyValue = try await storage.secret(identifier: "openai")
        XCTAssertEqual(legacyValue, "sk-123")

        // The next save rewrites the item in the versioned format without losing data.
        try await storage.storeSecret("el;evenlabs=key", identifier: "elevenlabs")

        let rawPayload = try XCTUnwrap(readKeychainPayload(service: service))
        XCTAssertTrue(rawPayload.hasPrefix(SecureStorage.payloadVersionPrefix))

        let reloaded = SecureStorage(configuration: SecureStorageConfiguration(service: service))
        let migrated = try await reloaded.secret(identifier: "deepgram")
        let untouched = try await reloaded.secret(identifier: "openai")
        let added = try await reloaded.secret(identifier: "elevenlabs")
        XCTAssertEqual(migrated, "dg-key")
        XCTAssertEqual(untouched, "sk-123")
        XCTAssertEqual(added, "el;evenlabs=key")
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

private func addKeychainPayload(_ payload: String, service: String) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: aggregateAccount,
        kSecValueData as String: Data(payload.utf8)
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw SecureStorageError.unexpectedStatus(status)
    }
}

private func readKeychainPayload(service: String) -> String? {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: aggregateAccount
    ]
    query[kSecReturnData as String] = true

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

private func deleteKeychainItem(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: aggregateAccount
    ]
    SecItemDelete(query as CFDictionary)
}
