import Foundation
import Security

// MARK: - Device Identity Storage
//
// Backs `DeviceIdentity.deviceId` (TransportProtocol.swift). Split into its
// own file to keep `TransportProtocol.swift` within the length limit.

/// Persists the single device-identity string that names this install to
/// paired Macs. The production conformance keeps it in the Keychain so it
/// survives app deletion/reinstall; tests substitute an in-memory store.
public protocol DeviceIdentityStoring: Sendable {
    func loadDeviceId() -> String?
    func storeDeviceId(_ id: String)
}

/// Keychain-backed `DeviceIdentityStoring`.
///
/// Uses a dedicated service rather than the aggregate `SecureStorage` payload:
/// `SecureStorage` is an actor (the device ID must stay readable
/// synchronously) and its legacy-secret migration absorbs and deletes any
/// standalone account it finds under its own service.
public struct KeychainDeviceIdentityStore: DeviceIdentityStoring {
    private let service: String
    private let account: String

    public init(
        service: String = "com.speak.ios.device-identity",
        account: String = "speak-device-id"
    ) {
        self.service = service
        self.account = account
    }

    public func loadDeviceId() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let id = String(data: data, encoding: .utf8),
              !id.isEmpty
        else {
            return nil
        }
        return id
    }

    /// Best-effort: a Keychain failure must never block identification, so
    /// callers fall back to the UserDefaults mirror written alongside.
    public func storeDeviceId(_ id: String) {
        let data = Data(id.utf8)
        let status = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecItemNotFound else { return }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        // Readable after first unlock, and *not* synchronizable: the identity
        // names this physical device, so it must never follow the user's
        // iCloud Keychain onto another device.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
