import Foundation
import Security

/// Updates only protection metadata, then verifies both protection and exact bytes.
/// Never delete/re-add: an unsupported update must leave the original secret intact.
enum KeychainAccessibilityMigration {
    static func migrate(
        query: [String: Any],
        expectedData: Data,
        copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching,
        update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
    ) throws {
        var readQuery = query
        readQuery[kSecReturnAttributes as String] = true
        readQuery[kSecReturnData as String] = true
        func read() throws -> [String: Any] {
            var result: CFTypeRef?
            let status = copy(readQuery as CFDictionary, &result)
            guard status == errSecSuccess, let attributes = result as? [String: Any],
                  attributes[kSecValueData as String] as? Data == expectedData else {
                throw SecureStorageError.unexpectedStatus(status == errSecSuccess ? errSecDecode : status)
            }
            return attributes
        }
        let accessibility = kSecAttrAccessibleAfterFirstUnlock as String
        let original = try read()
        guard original[kSecAttrAccessible as String] as? String != accessibility else { return }
        let status = update(query as CFDictionary, [kSecAttrAccessible as String: accessibility] as CFDictionary)
        guard status == errSecSuccess else { throw SecureStorageError.unexpectedStatus(status) }
        let verified = try read()
        guard verified[kSecAttrAccessible as String] as? String == accessibility else {
            throw SecureStorageError.unexpectedStatus(errSecDecode)
        }
    }
}
