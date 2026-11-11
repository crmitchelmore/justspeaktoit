import CryptoKit
import Foundation
import SpeakCore

/// Device-local key-sync state kept in its own non-synchronising Keychain
/// service: the passphrase-derived key and, per identifier, when the local
/// copy last matched CloudKit.
@MainActor
struct KeySyncLocalState {
    private static let derivedKeyIdentifier = "cloudkitKeySync.derivedKey"
    private static let updatedAtPrefix = "speak.keysync.localUpdatedAt."

    let storage: any CloudKitKeySyncSecretStoring

    func storeDerivedKey(_ key: SymmetricKey) async throws {
        try await storage.storeSecret(
            key.withUnsafeBytes { Data($0).base64EncodedString() },
            identifier: Self.derivedKeyIdentifier
        )
    }

    /// The saved derived key, or nil when it is missing or unreadable.
    func loadDerivedKey() async -> SymmetricKey? {
        guard let stored = try? await storage.secret(identifier: Self.derivedKeyIdentifier),
              let data = Data(base64Encoded: stored) else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    func removeDerivedKey() async throws {
        try await storage.removeSecret(identifier: Self.derivedKeyIdentifier)
    }

    func saveUpdatedAt(_ date: Date, identifier: String) async throws {
        try await storage.storeSecret(
            String(date.timeIntervalSince1970),
            identifier: Self.updatedAtPrefix + identifier
        )
    }

    func loadUpdatedAt(identifier: String) async throws -> Date? {
        let value: String
        do {
            value = try await storage.secret(identifier: Self.updatedAtPrefix + identifier)
        } catch SecureStorageError.valueNotFound {
            return nil
        }
        guard let timestamp = TimeInterval(value) else {
            throw CloudKitKeySyncError.malformedRecord
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    func removeUpdatedAt(identifier: String) async throws {
        try await storage.removeSecret(identifier: Self.updatedAtPrefix + identifier)
    }
}
