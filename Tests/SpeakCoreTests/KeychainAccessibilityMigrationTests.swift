import Foundation
import Security
import XCTest

@testable import SpeakCore

final class KeychainAccessibilityMigrationTests: XCTestCase {
    func testDefaultAndSynchronizablePolicies_remainUnchanged() {
        XCTAssertNil(SecureStorageConfiguration.default.keychainAccessibility)
        XCTAssertNil(SecureStorageConfiguration(synchronizable: true).keychainAccessibility)
        XCTAssertEqual(
            SecureStorageConfiguration(accessGroup: "test", synchronizable: true).keychainAccessibility,
            kSecAttrAccessibleAfterFirstUnlock
        )
        XCTAssertEqual(
            SecureStorageConfiguration(accessibility: .afterFirstUnlock).keychainAccessibility,
            kSecAttrAccessibleAfterFirstUnlock
        )
    }

    func testMigration_preservesExactCompatibilityAndOverflowBytesAndIsIdempotent() throws {
        for payload in ["deepgram.apiKey=synthetic-key", "v2:;custom=synthetic%3Bvalue"] {
            let originalData = Data(payload.utf8)
            var attributes: [String: Any] = [
                kSecValueData as String: originalData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ]
            var updates = 0
            let copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { _, result in
                result?.pointee = attributes as CFDictionary
                return errSecSuccess
            }
            let update: (CFDictionary, CFDictionary) -> OSStatus = { _, changes in
                guard let values = changes as NSDictionary as? [String: Any] else {
                    XCTFail("Invalid update attributes")
                    return errSecParam
                }
                XCTAssertEqual(Set(values.keys), [kSecAttrAccessible as String])
                attributes.merge(values) { _, new in new }
                updates += 1
                return errSecSuccess
            }
            for _ in 0..<2 {
                try KeychainAccessibilityMigration.migrate(
                    query: [:], expectedData: originalData, copy: copy, update: update
                )
            }
            XCTAssertEqual(updates, 1)
            XCTAssertEqual(attributes[kSecValueData as String] as? Data, originalData)
        }
    }

    func testDeniedUpdate_retainsOriginalAndCanRetry() throws {
        let data = Data("synthetic=unchanged".utf8)
        let original: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        var attempts = 0
        XCTAssertThrowsError(try KeychainAccessibilityMigration.migrate(
            query: [:], expectedData: data,
            copy: { _, result in result?.pointee = original as CFDictionary; return errSecSuccess },
            update: { _, _ in attempts += 1; return errSecInteractionNotAllowed }
        ))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(original[kSecValueData as String] as? Data, data)
    }

    func testUnreadableOrChangedItem_isNeverUpdated() {
        for status in [errSecInteractionNotAllowed, errSecSuccess] {
            XCTAssertThrowsError(try KeychainAccessibilityMigration.migrate(
                query: [:], expectedData: Data("synthetic".utf8),
                copy: { _, result in
                    result?.pointee = [kSecValueData as String: Data("changed".utf8)] as CFDictionary
                    return status
                },
                update: { _, _ in XCTFail("Must not update an unreadable or changed item"); return errSecSuccess }
            ))
        }
    }

    func testSuccessfulUpdate_isVerified() {
        let data = Data("synthetic".utf8)
        XCTAssertThrowsError(try KeychainAccessibilityMigration.migrate(
            query: [:], expectedData: data,
            copy: { _, result in
                result?.pointee = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
                ] as CFDictionary
                return errSecSuccess
            },
            update: { _, _ in errSecSuccess }
        ))
    }
}
