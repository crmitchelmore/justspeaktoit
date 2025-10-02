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
  private let masterAccount = "speak-app-secrets"
  private nonisolated let permissionsManager: PermissionsManager
  private nonisolated let appSettings: AppSettings
  private var cache: [String: String]
  private var didLoadFromKeychain = false

  init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
    cache = [:]
  }

  func storeSecret(_ value: String, identifier: String, label _: String? = nil) async throws {
    try await ensureCacheLoaded()

    guard await permissionsManager.ensureKeychainAccess(forService: service) else {
      throw SecureAppStorageError.permissionDenied
    }

    cache[identifier] = value
    try writeCacheToKeychain()

    await MainActor.run {
      appSettings.registerAPIKeyIdentifier(identifier)
    }
  }

  func secret(identifier: String) async throws -> String {
    try await ensureCacheLoaded()

    guard let cached = cache[identifier] else {
      throw SecureAppStorageError.valueNotFound
    }

    return cached
  }

  func removeSecret(identifier: String) async throws {
    try await ensureCacheLoaded()

    cache.removeValue(forKey: identifier)

    guard await permissionsManager.ensureKeychainAccess(forService: service) else {
      throw SecureAppStorageError.permissionDenied
    }

    try writeCacheToKeychain()

    await MainActor.run {
      appSettings.removeAPIKeyIdentifier(identifier)
    }
  }

  func knownIdentifiers() async -> [String] {
    try? await ensureCacheLoaded()
    return cache.keys.sorted()
  }

  func hasSecret(identifier: String) async -> Bool {
    try? await ensureCacheLoaded()
    if let cached = cache[identifier]?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
      return true
    }

    return false
  }

  func preloadTrackedSecrets() async {
    try? await ensureCacheLoaded()
  }

  private func ensureCacheLoaded() async throws {
    if didLoadFromKeychain { return }

    guard await permissionsManager.ensureKeychainAccess(forService: service) else {
      throw SecureAppStorageError.permissionDenied
    }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: masterAccount,
      kSecReturnData as String: true,
    ]

    var item: CFTypeRef?
    var status = SecItemCopyMatching(query as CFDictionary, &item)

    if status == errSecItemNotFound {
      try await migrateLegacySecretsIfNeeded()
      status = SecItemCopyMatching(query as CFDictionary, &item)
    }

    if status == errSecItemNotFound {
      cache = [:]
      didLoadFromKeychain = true
      return
    }

    guard status == errSecSuccess, let data = item as? Data,
      let payload = String(data: data, encoding: .utf8)
    else {
      throw SecureAppStorageError.unexpectedStatus(status)
    }

    cache = parse(payload: payload)
    didLoadFromKeychain = true

    let identifiers = Array(cache.keys)
    await MainActor.run {
      identifiers.forEach { appSettings.registerAPIKeyIdentifier($0) }
    }
  }

  private func migrateLegacySecretsIfNeeded() async throws {
    let trackedIdentifiers = await MainActor.run { appSettings.trackedAPIKeyIdentifiers }
    let legacyAccounts = try fetchLegacyAccounts()
    let candidates = Set(trackedIdentifiers).union(legacyAccounts)
      .subtracting([masterAccount])

    guard !candidates.isEmpty else { return }

    var migrated: [String: String] = [:]

    for identifier in candidates {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: identifier,
        kSecReturnData as String: true,
      ]

      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)

      if status == errSecItemNotFound {
        continue
      }

      guard status == errSecSuccess, let data = item as? Data,
        let value = String(data: data, encoding: .utf8)
      else {
        throw SecureAppStorageError.unexpectedStatus(status)
      }

      migrated[identifier] = value
    }

    guard !migrated.isEmpty else { return }

    cache = migrated
    try writeCacheToKeychain()
    migrated.keys.forEach { deleteLegacySecret(identifier: $0) }
    cache = [:]
    didLoadFromKeychain = false
  }

  private func fetchLegacyAccounts() throws -> [String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound {
      return []
    }

    guard status == errSecSuccess else {
      throw SecureAppStorageError.unexpectedStatus(status)
    }

    guard let array = result as? [[String: Any]] else { return [] }
    return array.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  private func deleteLegacySecret(identifier: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: identifier,
    ]

    SecItemDelete(query as CFDictionary)
  }

  private func writeCacheToKeychain() throws {
    let payload = serialize(cache: cache)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: masterAccount,
    ]

    if payload.isEmpty {
      SecItemDelete(query as CFDictionary)
      return
    }

    let data = Data(payload.utf8)
    let attributesToUpdate: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrLabel as String: masterAccount,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]

    let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
    if status == errSecItemNotFound {
      var addQuery = query
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrLabel as String] = masterAccount
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw SecureAppStorageError.unexpectedStatus(addStatus)
      }
    } else if status != errSecSuccess {
      throw SecureAppStorageError.unexpectedStatus(status)
    }
  }

  private func parse(payload: String) -> [String: String] {
    payload
      .split(separator: ";")
      .reduce(into: [String: String]()) { partialResult, item in
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let components = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let keyComponent = components.first else { return }
        let key = String(keyComponent)
        let value = components.count > 1 ? String(components[1]) : ""
        partialResult[key] = value
      }
  }

  private func serialize(cache: [String: String]) -> String {
    cache
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: ";")
  }

}
