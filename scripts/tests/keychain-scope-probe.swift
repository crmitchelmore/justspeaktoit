import Foundation
import Security

@main
struct KeychainScopeProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let service = "com.justspeaktoit.process-isolation.probe"
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        func expect(_ actual: OSStatus, _ expected: OSStatus = errSecSuccess) {
            guard actual == expected else {
                fputs("unexpected Security status: \(actual), expected \(expected)\n", stderr)
                exit(1)
            }
        }
        func read(_ query: [String: Any], expected: String) {
            var query = query
            query[kSecReturnData as String] = true
            var value: CFTypeRef?
            expect(KeychainAccess.copyMatching(query as CFDictionary, &value))
            guard let data = value as? Data, String(data: data, encoding: .utf8) == expected else { exit(2) }
        }
        switch args[1] {
        case "seed", "hold":
            var item = base
            item[kSecAttrAccount as String] = "sentinel"
            item[kSecValueData as String] = Data("outside".utf8)
            expect(KeychainAccess.add(item as CFDictionary, nil))
            if args[1] == "hold" {
                let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                    "path": ProcessInfo.processInfo.environment["JSTI_TEST_KEYCHAIN_PATH"]!]
                try JSONSerialization.data(withJSONObject: state).write(to: URL(fileURLWithPath: args[2]))
                Thread.sleep(forTimeInterval: 60)
            }
        case "check":
            read(base, expected: "outside")
        case "lock-check", "bad-password":
            var keychain: SecKeychain?
            expect(SecKeychainOpen(ProcessInfo.processInfo.environment["JSTI_TEST_KEYCHAIN_PATH"]!, &keychain))
            expect(SecKeychainLock(keychain))
            if args[1] == "bad-password" {
                expect(KeychainAccess.copyMatching(base as CFDictionary, nil), errSecAuthFailed)
                expect(KeychainAccess.delete(base as CFDictionary), errSecAuthFailed)
            } else {
                read(base, expected: "outside")
            }
        case "unscoped-check":
            var keychain: SecKeychain?
            expect(SecKeychainOpen(args[2], &keychain))
            var query = base
            query[kSecMatchSearchList as String] = [keychain!]
            read(query, expected: "outside")
        case "exercise":
            expect(KeychainAccess.copyMatching(base as CFDictionary, nil), errSecItemNotFound)
            var item = base
            item[kSecAttrAccount as String] = "value"
            item[kSecValueData as String] = Data("first".utf8)
            expect(KeychainAccess.add(item as CFDictionary, nil))
            read(base, expected: "first")
            expect(KeychainAccess.update(base as CFDictionary,
                [kSecValueData as String: Data("second".utf8)] as CFDictionary))
            read(base, expected: "second")
            // Explicit alternate search lists cannot escape the scoped Keychain.
            var other: SecKeychain?
            expect(SecKeychainOpen(args[2], &other))
            var escape = base
            escape[kSecAttrAccount as String] = "sentinel"
            escape[kSecMatchSearchList as String] = [other!]
            expect(KeychainAccess.copyMatching(escape as CFDictionary, nil), errSecItemNotFound)
            var sync = base
            sync[kSecAttrSynchronizable as String] = true
            expect(KeychainAccess.add(sync as CFDictionary, nil), errSecMissingEntitlement)
            expect(KeychainAccess.update(base as CFDictionary,
                [kSecAttrSynchronizable as String: true] as CFDictionary), errSecMissingEntitlement)
            read(base, expected: "second")
            // A broad delete stays within the private Keychain, not the login/search list.
            expect(KeychainAccess.delete([kSecClass as String: kSecClassGenericPassword] as CFDictionary))
            expect(KeychainAccess.copyMatching(base as CFDictionary, nil), errSecItemNotFound)
        case "invalid":
            expect(KeychainAccess.copyMatching(base as CFDictionary, nil), errSecParam)
            expect(KeychainAccess.delete(base as CFDictionary), errSecParam)
        case "unwrapped-native":
            expect(KeychainAccess.copyMatching(base as CFDictionary, nil), errSecNotAvailable)
            expect(KeychainAccess.delete(base as CFDictionary), errSecNotAvailable)
        default: exit(3)
        }
    }
}
