#if canImport(Security)
import Foundation
import Security
#if os(macOS)
import Darwin
#endif

/// One Security boundary for app code and credential fixtures. Native CI supplies
/// a private file Keychain per process; ordinary app launches retain OS behaviour.
public enum KeychainAccess {
    public static func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        perform(query, adding: true) { SecItemAdd($0, result) }
    }

    public static func copyMatching(
        _ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        perform(query) { SecItemCopyMatching($0, result) }
    }

    public static func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        #if os(macOS)
        if ProcessInfo.processInfo.environment["JSTI_TEST_KEYCHAIN_PATH"] != nil {
            guard let values = attributes as? [String: Any] else { return errSecParam }
            let status = privateQueryStatus(values)
            guard status == errSecSuccess else { return status }
            if values[kSecUseKeychain as String] != nil || values[kSecMatchSearchList as String] != nil {
                return errSecParam
            }
        }
        #endif
        return perform(query) { SecItemUpdate($0, attributes) }
    }

    public static func delete(_ query: CFDictionary) -> OSStatus {
        perform(query) { SecItemDelete($0) }
    }

    private static func privateQueryStatus(_ query: [String: Any]) -> OSStatus {
        // These routes cannot target a private file Keychain; never fall through
        // to desktop/iCloud items or an existing item reference.
        if query[kSecAttrSynchronizable as String] as? Bool == true
            || query[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String
            || query[kSecUseDataProtectionKeychain as String] as? Bool == true {
            return errSecMissingEntitlement
        }
        if query[kSecValueRef as String] != nil || query[kSecValuePersistentRef as String] != nil {
            return errSecParam
        }
        return errSecSuccess
    }

    #if os(macOS)
    private static func canonicalFilePath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    #endif

    private static func perform(
        _ query: CFDictionary, adding: Bool = false, operation: (CFDictionary) -> OSStatus
    ) -> OSStatus {
        #if os(macOS)
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["JSTI_TEST_KEYCHAIN_PATH"] else {
            // An unwrapped native CI test must fail rather than use the desktop vault.
            if environment["RUNNER_ENVIRONMENT"] == "self-hosted" {
                return errSecNotAvailable
            }
            return operation(query)
        }
        let file = URL(fileURLWithPath: path)
        let directory = file.deletingLastPathComponent()
        guard path.hasPrefix("/"), file.lastPathComponent == "tests.keychain-db",
              directory.lastPathComponent.hasPrefix("jsti-ci-keychain-"),
              canonicalFilePath(path) == path,
              (try? String(contentsOf: directory.appendingPathComponent(".jsti-test-keychain"),
                           encoding: .utf8)) == path else {
            return errSecParam
        }
        guard var scoped = query as? [String: Any] else { return errSecParam }
        let queryStatus = privateQueryStatus(scoped)
        guard queryStatus == errSecSuccess else { return queryStatus }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            return errSecInteractionNotAllowed
        }
        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else {
            return status == errSecSuccess ? errSecInvalidKeychain : status
        }
        guard let password = environment["JSTI_TEST_KEYCHAIN_PASSWORD"], !password.isEmpty else {
            return errSecAuthFailed
        }
        let unlock = password.withCString {
            SecKeychainUnlock(keychain, UInt32(password.utf8.count), UnsafeRawPointer($0), true)
        }
        guard unlock == errSecSuccess else { return unlock }
        scoped.removeValue(forKey: kSecUseKeychain as String)
        scoped.removeValue(forKey: kSecMatchSearchList as String)
        if adding {
            scoped[kSecUseKeychain as String] = keychain
        } else {
            scoped[kSecMatchSearchList as String] = [keychain]
        }
        return operation(scoped as CFDictionary)
        #else
        return operation(query)
        #endif
    }
}
#endif
