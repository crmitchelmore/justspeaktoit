# DEFINITIVE FIX for macOS Keychain Error -34018

## TL;DR - The Root Cause

**Error -34018 (errSecMissingEntitlement) is triggered by `kSecAttrSynchronizable = true` without the `keychain-access-groups` entitlement.**

Your codebase already has the correct solution implemented. If you're still seeing the error, see the diagnostic steps below.

## Quick Diagnostic

Run this command to test keychain access:
```bash
./keychain_test.swift
```

Expected output:
```
Test 4: With kSecAttrSynchronizable attribute
  ✗ FAILED - Error -34018 (errSecMissingEntitlement)
  → This means kSecAttrSynchronizable requires keychain-access-groups entitlement
```

## The 3 Facts About macOS Keychain + Hardened Runtime

1. ✅ **Hardened runtime does NOT block basic keychain access**
   - No special entitlements needed for `SecItemAdd`/`SecItemUpdate`/etc.
   - Works with standard attributes: `kSecAttrService`, `kSecAttrAccount`, `kSecValueData`

2. ✅ **`kSecAttrAccessible` works on macOS without entitlements**
   - Unlike iOS where it triggers -34018
   - macOS is more permissive for non-sandboxed apps

3. ❌ **`kSecAttrSynchronizable = true` ALWAYS requires entitlements**
   - Triggers -34018 on Developer ID builds
   - Requires `keychain-access-groups` entitlement
   - This entitlement requires Mac App Store or Enterprise distribution

## Your Current Implementation (Already Correct!)

### File: `Sources/SpeakApp/SecureAppStorage.swift`

```swift
// Runtime detection - tests if entitlement is available
let hasAccessGroupEntitlement = Self.hasKeychainAccessGroupEntitlement()

let configuration = SecureStorageConfiguration(
    service: "com.justspeaktoit.credentials",
    masterAccount: "speak-app-secrets",
    accessGroup: hasAccessGroupEntitlement ? "8X4ZN58TYH.com.justspeaktoit.shared" : nil,
    synchronizable: hasAccessGroupEntitlement  // ← Only true if entitlement exists
)
```

This is **exactly the right approach** and matches industry best practices.

## If You're Still Seeing -34018 Errors

### Step 1: Add Debug Logging

**File: `Sources/SpeakApp/SecureAppStorage.swift`** (after line 88):

```swift
self.storage = SecureStorage(
    configuration: configuration,
    permissionsChecker: PermissionsManagerBridge(permissionsManager: permissionsManager),
    identifierRegistry: appSettings
)

// DEBUG: Log configuration
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("[SecureAppStorage] Configuration:")
print("  service: \(configuration.service)")
print("  accessGroup: \(configuration.accessGroup ?? "nil")")
print("  synchronizable: \(configuration.synchronizable)")
print("  hasEntitlement: \(hasAccessGroupEntitlement)")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
```

**Run the app and check console output.** You should see:
```
[SecureAppStorage] No keychain-access-groups entitlement (status: -34018), using app-local keychain
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[SecureAppStorage] Configuration:
  service: com.justspeaktoit.credentials
  accessGroup: nil
  synchronizable: false
  hasEntitlement: false
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 2: If synchronizable is TRUE, you have a problem

If you see `synchronizable: true` in the debug output, something is bypassing the detection.

**Fix Option A: Defensive validation**

**File: `Sources/SpeakCore/SecureStorage.swift`** (line 338-341):

```swift
// OLD CODE:
if configuration.synchronizable {
    attributesToUpdate[kSecAttrSynchronizable as String] = kCFBooleanTrue
}

// NEW CODE (defensive):
if configuration.synchronizable {
    // DEFENSIVE: Verify we have access group before enabling sync
    guard configuration.accessGroup != nil else {
        print("⚠️ WARNING: synchronizable=true without accessGroup, skipping sync")
        // Option 1: Skip the attribute (app continues to work)
        // Option 2: Throw error to catch the bug during development
        // throw SecureStorageError.permissionDenied
        break  // Skip setting this attribute
    }
    attributesToUpdate[kSecAttrSynchronizable as String] = kCFBooleanTrue
}
```

Apply the same fix at line 352-354:
```swift
if configuration.synchronizable {
    guard configuration.accessGroup != nil else {
        print("⚠️ WARNING: synchronizable=true without accessGroup, skipping sync")
        break
    }
    addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
}
```

### Step 3: Check for Direct SecItem Calls

Your codebase has one direct `SecItemAdd` call in `Sources/SpeakiOS/Views/SettingsView.swift:58`.

**Verify it's safe** (it is, but worth checking):

```swift
// This is SAFE - no synchronizable or access group
let addQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecValueData as String: key.data(using: .utf8)!
    // ✓ No kSecAttrSynchronizable
    // ✓ No kSecAttrAccessGroup
]
SecItemAdd(addQuery as CFDictionary, nil)
```

This is fine and won't trigger -34018.

## The Minimal Working Example

For any new keychain code, use this pattern:

```swift
// ✅ WORKS - No entitlements needed
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "your.service.identifier",
    kSecAttrAccount as String: "account-name",
    kSecValueData as String: secretData
]
SecItemAdd(query as CFDictionary, nil)

// ❌ FAILS with -34018 (unless you have entitlements)
let syncQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "your.service.identifier",
    kSecAttrAccount as String: "account-name",
    kSecValueData as String: secretData,
    kSecAttrSynchronizable as String: kCFBooleanTrue  // ← This triggers -34018
]
SecItemAdd(syncQuery as CFDictionary, nil)
```

## Adding the keychain-access-groups Entitlement (For Mac App Store)

If you want iCloud Keychain sync for Mac App Store builds:

**File: `Config/SpeakMacOS.entitlements`** (uncomment lines 57-62):

```xml
<!-- Keychain sharing - requires managed profile -->
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.justspeaktoit.shared</string>
</array>
```

**Important:**
- This ONLY works for Mac App Store builds
- Developer ID builds will ignore this entitlement
- The runtime detection will still work correctly

## Testing Checklist

After implementing fixes:

```bash
# 1. Clean build
rm -rf .build
swift build

# 2. Run diagnostic
./keychain_test.swift

# 3. Run app and check console
swift run

# 4. Look for these messages:
#    "[SecureAppStorage] No keychain-access-groups entitlement"
#    "synchronizable: false"
#    "accessGroup: nil"

# 5. Test keychain operations
#    - Save an API key
#    - Restart app
#    - Verify key is still there
```

## What Other Apps Do (Raycast, Alfred, 1Password, etc.)

They ALL use the same pattern:

1. **Never assume entitlements exist**
   - Test at runtime
   - Fall back gracefully

2. **Developer ID = No iCloud Keychain**
   - Use app-local keychain
   - Implement alternative sync (own server, QR codes, etc.)

3. **Mac App Store = iCloud Keychain enabled**
   - Same binary, different entitlements
   - Runtime detection handles both cases

## Final Answer to Your Questions

### 1. What EXACTLY causes -34018?

**`kSecAttrSynchronizable = true` without `keychain-access-groups` entitlement.**

Nothing else. Not hardened runtime, not sandboxing, not Developer ID signing.

### 2. Does hardened runtime require keychain entitlements?

**No.** Hardened runtime does NOT require special entitlements for basic keychain access.

### 3. Legacy keychain vs Data Protection keychain?

**Legacy:** No `kSecAttrAccessible` → Works everywhere, no entitlements  
**Data Protection:** Has `kSecAttrAccessible` → Works on macOS without entitlements (unlike iOS)

**Recommendation:** Use legacy (no kSecAttrAccessible) for maximum compatibility.

### 4. What attributes trigger -34018?

| Attribute | Triggers -34018? |
|-----------|-----------------|
| `kSecAttrSynchronizable = true` | ✅ YES |
| `kSecAttrAccessGroup` | ⚠️ Maybe (in production) |
| `kSecAttrAccessible` | ❌ No (on macOS) |
| Everything else | ❌ No |

### 5. How do other apps handle this?

**They do exactly what you're already doing:** Runtime detection + graceful fallback.

## Code to Remove (if present)

If you see this anywhere, remove it:

```swift
// ❌ DON'T hardcode synchronizable
let config = SecureStorageConfiguration(synchronizable: true)

// ❌ DON'T hardcode access group for Developer ID
let config = SecureStorageConfiguration(
    accessGroup: "8X4ZN58TYH.com.justspeaktoit.shared"
)

// ✅ DO let SecureAppStorage detect it
let storage = SecureAppStorage(
    permissionsManager: permissionsManager,
    appSettings: appSettings
)
```

## Summary

Your code is already correct. If you're seeing -34018:

1. Add debug logging (see Step 1)
2. Verify `synchronizable = false` and `accessGroup = nil`
3. Add defensive guards (see Step 2) to catch configuration bugs
4. Check for any code directly setting `kSecAttrSynchronizable = true`

The most likely culprit is a custom configuration being passed somewhere that bypasses the runtime detection.
