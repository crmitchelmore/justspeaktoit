import Foundation

// MARK: - Transactional import (issue #699)

extension ConfigTransferManager {
    /// Applies an imported payload transactionally.
    ///
    /// Before any mutation the payload is validated against the bounded
    /// transfer policy and every destination value is read and retained. On a
    /// failed write, every already-applied secret is rolled back to its
    /// retained value; if rollback itself fails, the identifiers left in the
    /// imported state are reported. Settings are applied last (their writes
    /// cannot fail), so a secret failure never leaves partial settings.
    ///
    /// The Keychain offers no multi-item transaction, so an import interrupted
    /// by process death can leave earlier writes applied; retrying the same
    /// import re-applies identical values and converges — it can never produce
    /// a configuration mixing two sources beyond the interrupted one.
    ///
    /// `liveModelDefaultsKey` mirrors `gatherSettings(defaults:liveModelDefaultsKey:)`:
    /// the payload always carries the shared `selectedModel` key, and the importing
    /// platform names the local UserDefaults key it reads its live transcription
    /// model from, so the selection lands where that platform will find it.
    public func applyImport(
        payload: ConfigTransferPayload,
        storage: SecureStorage,
        defaults: UserDefaults = .standard,
        liveModelDefaultsKey: String = "selectedModel"
    ) async throws {
        try Self.validateImport(payload: payload)

        // Retain the destination values for every key that will change. A read
        // failure other than "not stored" aborts before mutation.
        var previousValues: [String: String] = [:]
        for identifier in payload.secrets.keys.sorted() {
            do {
                previousValues[identifier] = try await storage.secret(identifier: identifier)
            } catch SecureStorageError.valueNotFound {
                continue
            }
        }

        var appliedIdentifiers: [String] = []
        do {
            for identifier in payload.secrets.keys.sorted() {
                guard let value = payload.secrets[identifier] else { continue }
                try await storage.storeSecret(value, identifier: identifier)
                appliedIdentifiers.append(identifier)
            }
        } catch {
            let stranded = await rollBack(
                identifiers: appliedIdentifiers,
                previousValues: previousValues,
                storage: storage
            )
            guard stranded.isEmpty else {
                throw ConfigTransferError.rollbackFailed(identifiers: stranded)
            }
            throw error
        }

        for (key, value) in payload.settings {
            let localKey = key == "selectedModel" ? liveModelDefaultsKey : key
            defaults.set(value, forKey: localKey)
            if key == Self.transcriptionKeywordsKey {
                // An import is an intentional write, even when its text equals
                // an earlier migration. Keep the legacy macOS mirror in sync.
                defaults.set(value, forKey: "assemblyAIKeyterms")
                defaults.set(value, forKey: "transcriptionKeywordsLastReconciled")
            }
        }
    }

    /// Refuses anything outside the bounded transfer policy before any write.
    ///
    /// Empty values are refused as well: export never produces them, and
    /// storing an empty secret would overwrite a working destination credential
    /// while unregistering its identifier.
    private static func validateImport(payload: ConfigTransferPayload) throws {
        for identifier in payload.secrets.keys.sorted() {
            guard transferableSecretIdentifiers.contains(identifier) else {
                throw ConfigTransferError.unknownSecretIdentifier(identifier)
            }
            if payload.secrets[identifier]?.isEmpty ?? true {
                throw ConfigTransferError.emptySecretValue(identifier)
            }
        }
        for key in payload.settings.keys.sorted() {
            guard transferableSettingKeys.contains(key) else {
                throw ConfigTransferError.unknownSettingKey(key)
            }
            if payload.settings[key]?.isEmpty ?? true {
                throw ConfigTransferError.emptySettingValue(key)
            }
        }
    }

    /// Restores each applied identifier to its retained value (or removes it
    /// when it did not exist). Returns the identifiers rollback failed for.
    private func rollBack(
        identifiers: [String],
        previousValues: [String: String],
        storage: SecureStorage
    ) async -> [String] {
        var failures: [String] = []
        for identifier in identifiers.reversed() {
            do {
                if let previous = previousValues[identifier] {
                    try await storage.storeSecret(previous, identifier: identifier)
                } else {
                    try await storage.removeSecret(identifier: identifier)
                }
            } catch {
                failures.append(identifier)
            }
        }
        return failures.sorted()
    }
}
