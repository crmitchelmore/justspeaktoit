import CryptoKit
import Foundation
import Security
import SpeakCore

/// Recovery credentials use a separate, device-only Keychain item. They never
/// enter the exportable credential registry or the readable recovery ZIP.
struct MigrationRecovery {
    let root: URL
    private let service = ReleaseTrain.current.namespace("com.justspeaktoit.migration-recovery")
    var directory: URL { root.appendingPathComponent("MigrationRecovery") }
    var exists: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovery.zip").path) }

    func save(_ snapshot: MigrationSnapshot) throws {
        let manager = FileManager.default
        let staging = root.appendingPathComponent(".recovery-\(UUID().uuidString)")
        try manager.createDirectory(
            at: staging,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let account = UUID().uuidString
        var installed = false
        defer {
            try? manager.removeItem(at: staging)
            if !installed {
                deleteKey(account)
            }
        }
        var publicSnapshot = snapshot
        if snapshot.manifest.categories.contains(.credentials) {
            let key = SymmetricKey(size: .bits256)
            try storeKey(key.withUnsafeBytes { Data($0) }, account: account)
            let data = try MigrationCoding.encoder.encode(snapshot.records[.credentials] ?? [])
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined
            else {
                throw MigrationError.invalid("Could not protect recovery credentials.")
            }
            try combined.write(to: staging.appendingPathComponent("credentials.encrypted"), options: .atomic)
            try Data(account.utf8).write(to: staging.appendingPathComponent("key-id"), options: .atomic)
            publicSnapshot.records[.credentials] = []
        }
        try MigrationArchive.write(publicSnapshot, to: staging.appendingPathComponent("recovery.zip"))
        let oldAccount = try? String(contentsOf: directory.appendingPathComponent("key-id"), encoding: .utf8)
        if manager.fileExists(atPath: directory.path) {
            _ = try manager.replaceItemAt(directory, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: directory)
        }
        installed = true
        if let oldAccount {
            deleteKey(oldAccount)
        }
    }

    func load() throws -> MigrationSnapshot {
        var snapshot = try MigrationArchive.read(directory.appendingPathComponent("recovery.zip"))
        if snapshot.manifest.categories.contains(.credentials) {
            do {
                let account = try String(
                    contentsOf: directory.appendingPathComponent("key-id"),
                    encoding: .utf8
                )
                let key = SymmetricKey(data: try readKey(account))
                let data = try Data(contentsOf: directory.appendingPathComponent("credentials.encrypted"))
                let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
                snapshot.records[.credentials] = try MigrationCoding.decoder.decode(
                    [MigrationRecord].self,
                    from: plain
                )
            } catch {
                if let directory = snapshot.directory {
                    try? FileManager.default.removeItem(at: directory)
                }
                throw MigrationError
                    .invalid("Recovery credentials could not be unlocked on this Mac. No data was changed.")
            }
        }
        return snapshot
    }

    func delete() throws {
        let account = try? String(contentsOf: directory.appendingPathComponent("key-id"), encoding: .utf8)
        if FileManager.default
            .fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        if let account {
            deleteKey(account)
        }
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    private func storeKey(_ data: Data, account: String) throws {
        var values = query(account)
        values[kSecValueData as String] = data
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else {
            throw MigrationError
                .invalid("Keychain could not protect the recovery backup. No data was changed.")
        }
    }
    private func readKey(_ account: String) throws -> Data {
        var values = query(account)
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(values as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            throw MigrationError.invalid("Recovery key unavailable")
        }
        return data
    }
    private func deleteKey(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
