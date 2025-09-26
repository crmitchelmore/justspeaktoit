import Foundation
import Security

// @Implement: This file should provide secure storage and retrieval of sensitive app data such as API keys, user credentials, etc. It should use Keychain services on macOS for secure storage. It depends on the permissions manager to check for necessary permissions. Should have an in memory cache to avoid frequent keychain access. And store in app settings what keys we have so we can list without accessing keychain

enum SecureAppStorageError: LocalizedError {
  case permissionDenied
  case valueNotFound
  case unexpectedStatus(OSStatus)

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      return "Keychain access was denied. Please review your Security & Privacy settings."
    case .valueNotFound:
      return "No value found for the requested identifier."
    case .unexpectedStatus(let status):
      if let message = SecCopyErrorMessageString(status, nil) as String? {
        return message
      }
      return "Keychain returned status \(status)."
    }
  }
}

actor SecureAppStorage {
  private let service = "com.github.speakapp.credentials"
  private nonisolated let permissionsManager: PermissionsManager
  private nonisolated let appSettings: AppSettings
  private var cache: [String: String]

  init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
    cache = [:]
  }

  func storeSecret(_ value: String, identifier: String, label: String? = nil) async throws {
    guard await permissionsManager.ensureKeychainAccess() else {
      throw SecureAppStorageError.permissionDenied
    }

    cache[identifier] = value

    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: identifier,
    ]

    let attributesToUpdate: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrLabel as String: label ?? identifier,
    ]

    let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
    if status == errSecItemNotFound {
      var addQuery = query
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrLabel as String] = label ?? identifier
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw SecureAppStorageError.unexpectedStatus(addStatus)
      }
    } else if status != errSecSuccess {
      throw SecureAppStorageError.unexpectedStatus(status)
    }

    await MainActor.run {
      appSettings.registerAPIKeyIdentifier(identifier)
    }
  }

  func secret(identifier: String) async throws -> String {
    if let cached = cache[identifier] {
      return cached
    }

    guard await permissionsManager.ensureKeychainAccess() else {
      throw SecureAppStorageError.permissionDenied
    }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: identifier,
      kSecReturnData as String: true,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)

    guard status != errSecItemNotFound else { throw SecureAppStorageError.valueNotFound }
    guard status == errSecSuccess, let data = item as? Data,
      let string = String(data: data, encoding: .utf8)
    else {
      throw SecureAppStorageError.unexpectedStatus(status)
    }

    cache[identifier] = string
    return string
  }

  func removeSecret(identifier: String) async throws {
    cache.removeValue(forKey: identifier)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: identifier,
    ]

    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecureAppStorageError.unexpectedStatus(status)
    }

    await MainActor.run {
      appSettings.removeAPIKeyIdentifier(identifier)
    }
  }

  func knownIdentifiers() async -> [String] {
    await MainActor.run {
      appSettings.trackedAPIKeyIdentifiers
    }
  }

  func hasSecret(identifier: String) async -> Bool {
    if let cached = cache[identifier]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !cached.isEmpty
    {
      return true
    }

    do {
      let value = try await secret(identifier: identifier)
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    } catch {
      return false
    }
  }
}
