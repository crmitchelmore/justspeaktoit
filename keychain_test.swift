#!/usr/bin/env swift

import Foundation
import Security

print("=== macOS Keychain Error -34018 Diagnostic Tool ===\n")

// Test 1: Basic keychain access without any special attributes
print("Test 1: Basic keychain access (no special attributes)")
let basicQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "test.service",
    kSecAttrAccount as String: "test.account",
    kSecValueData as String: "test data".data(using: .utf8)!
]
let basicStatus = SecItemAdd(basicQuery as CFDictionary, nil)
print("  Status: \(basicStatus)")
if basicStatus == errSecSuccess || basicStatus == errSecDuplicateItem {
    print("  ✓ SUCCESS - Basic keychain access works")
    SecItemDelete(basicQuery as CFDictionary)
} else if basicStatus == -34018 {
    print("  ✗ FAILED - Error -34018 (errSecMissingEntitlement)")
} else {
    print("  ✗ FAILED - Error: \(basicStatus)")
}

// Test 2: With kSecAttrAccessible
print("\nTest 2: With kSecAttrAccessible attribute")
var accessibleQuery = basicQuery
accessibleQuery[kSecAttrAccount as String] = "test.account.2"
accessibleQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
let accessibleStatus = SecItemAdd(accessibleQuery as CFDictionary, nil)
print("  Status: \(accessibleStatus)")
if accessibleStatus == errSecSuccess || accessibleStatus == errSecDuplicateItem {
    print("  ✓ SUCCESS - kSecAttrAccessible works")
    SecItemDelete(accessibleQuery as CFDictionary)
} else if accessibleStatus == -34018 {
    print("  ✗ FAILED - Error -34018 (errSecMissingEntitlement)")
    print("  → This means kSecAttrAccessible requires keychain-access-groups entitlement")
} else {
    print("  ✗ FAILED - Error: \(accessibleStatus)")
}

// Test 3: With kSecAttrAccessGroup
print("\nTest 3: With kSecAttrAccessGroup attribute")
var accessGroupQuery = basicQuery
accessGroupQuery[kSecAttrAccount as String] = "test.account.3"
accessGroupQuery[kSecAttrAccessGroup as String] = "8X4ZN58TYH.com.justspeaktoit.shared"
let accessGroupStatus = SecItemAdd(accessGroupQuery as CFDictionary, nil)
print("  Status: \(accessGroupStatus)")
if accessGroupStatus == errSecSuccess || accessGroupStatus == errSecDuplicateItem {
    print("  ✓ SUCCESS - kSecAttrAccessGroup works")
    SecItemDelete(accessGroupQuery as CFDictionary)
} else if accessGroupStatus == -34018 {
    print("  ✗ FAILED - Error -34018 (errSecMissingEntitlement)")
    print("  → This confirms keychain-access-groups entitlement is missing")
} else {
    print("  ✗ FAILED - Error: \(accessGroupStatus)")
}

// Test 4: With kSecAttrSynchronizable
print("\nTest 4: With kSecAttrSynchronizable attribute")
var syncQuery = basicQuery
syncQuery[kSecAttrAccount as String] = "test.account.4"
syncQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
let syncStatus = SecItemAdd(syncQuery as CFDictionary, nil)
print("  Status: \(syncStatus)")
if syncStatus == errSecSuccess || syncStatus == errSecDuplicateItem {
    print("  ✓ SUCCESS - kSecAttrSynchronizable works")
    SecItemDelete(syncQuery as CFDictionary)
} else if syncStatus == -34018 {
    print("  ✗ FAILED - Error -34018 (errSecMissingEntitlement)")
    print("  → This means kSecAttrSynchronizable requires keychain-access-groups entitlement")
} else {
    print("  ✗ FAILED - Error: \(syncStatus)")
}

print("\n=== Summary ===")
print("The following attributes trigger -34018 without keychain-access-groups entitlement:")
if accessibleStatus == -34018 { print("  • kSecAttrAccessible") }
if accessGroupStatus == -34018 { print("  • kSecAttrAccessGroup") }
if syncStatus == -34018 { print("  • kSecAttrSynchronizable") }

print("\nSolution: Remove these attributes for non-sandboxed, hardened runtime apps")
print("that don't have the keychain-access-groups entitlement.")
