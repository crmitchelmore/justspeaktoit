#!/usr/bin/env swift

import Foundation
import Security

print("=== Detailed macOS Keychain Analysis ===\n")

func testKeychainScenario(_ name: String, _ query: [String: Any]) {
    print("Test: \(name)")
    let status = SecItemAdd(query as CFDictionary, nil)
    
    if status == errSecSuccess || status == errSecDuplicateItem {
        print("  ✓ SUCCESS (status: \(status))")
        SecItemDelete(query as CFDictionary)
    } else {
        print("  ✗ FAILED (status: \(status))")
        if status == -34018 {
            print("    → errSecMissingEntitlement")
        } else if let message = SecCopyErrorMessageString(status, nil) {
            print("    → \(message)")
        }
    }
    print()
}

// Base query
let baseQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.test.diagnostic",
    kSecValueData as String: "test".data(using: .utf8)!
]

// Test 1: Minimal query (LEGACY KEYCHAIN)
var test1 = baseQuery
test1[kSecAttrAccount as String] = "test1"
testKeychainScenario("Minimal query (LEGACY)", test1)

// Test 2: With kSecAttrAccessible = kSecAttrAccessibleWhenUnlocked
var test2 = baseQuery
test2[kSecAttrAccount as String] = "test2"
test2[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
testKeychainScenario("kSecAttrAccessible = WhenUnlocked (DATA PROTECTION)", test2)

// Test 3: With kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock
var test3 = baseQuery
test3[kSecAttrAccount as String] = "test3"
test3[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
testKeychainScenario("kSecAttrAccessible = AfterFirstUnlock (DATA PROTECTION)", test3)

// Test 4: With kSecAttrAccessible = kSecAttrAccessibleAlways (deprecated)
var test4 = baseQuery
test4[kSecAttrAccount as String] = "test4"
test4[kSecAttrAccessible as String] = kSecAttrAccessibleAlways
testKeychainScenario("kSecAttrAccessible = Always [deprecated] (DATA PROTECTION)", test4)

// Test 5: With kSecAttrSynchronizable = true
var test5 = baseQuery
test5[kSecAttrAccount as String] = "test5"
test5[kSecAttrSynchronizable as String] = kCFBooleanTrue
testKeychainScenario("kSecAttrSynchronizable = true", test5)

// Test 6: With kSecAttrSynchronizable = false (explicit)
var test6 = baseQuery
test6[kSecAttrAccount as String] = "test6"
test6[kSecAttrSynchronizable as String] = kCFBooleanFalse
testKeychainScenario("kSecAttrSynchronizable = false (explicit)", test6)

// Test 7: Combination: kSecAttrAccessible + kSecAttrSynchronizable
var test7 = baseQuery
test7[kSecAttrAccount as String] = "test7"
test7[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
test7[kSecAttrSynchronizable as String] = kCFBooleanTrue
testKeychainScenario("Both kSecAttrAccessible + kSecAttrSynchronizable", test7)

// Test 8: With kSecAttrAccessGroup (requires entitlement)
var test8 = baseQuery
test8[kSecAttrAccount as String] = "test8"
test8[kSecAttrAccessGroup as String] = "TEAMID.com.example.shared"
testKeychainScenario("kSecAttrAccessGroup (requires entitlement)", test8)

print("=== KEY FINDINGS ===")
print("1. LEGACY KEYCHAIN: No special attributes = works without entitlements")
print("2. DATA PROTECTION KEYCHAIN: Using kSecAttrAccessible may work on macOS")
print("   (unlike iOS where it always requires entitlements)")
print("3. kSecAttrSynchronizable: REQUIRES keychain-access-groups entitlement")
print("4. kSecAttrAccessGroup: REQUIRES keychain-access-groups entitlement")
print("\nFor non-sandboxed, hardened runtime apps without entitlements:")
print("  DO:     Use minimal keychain queries (legacy keychain)")
print("  AVOID:  kSecAttrSynchronizable, kSecAttrAccessGroup")
print("  MAYBE:  kSecAttrAccessible (test on target macOS versions)")
