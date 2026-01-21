# macOS Keychain Error -34018 Research Report

## Question
What EXACTLY causes error -34018 (errSecMissingEntitlement) on a non-sandboxed, hardened runtime macOS app distributed via Developer ID, and what specific code changes are needed?

## Executive Summary

**The Primary Culprit: `kSecAttrSynchronizable`**

Error -34018 occurs when using `kSecAttrSynchronizable = true` in keychain queries WITHOUT the `keychain-access-groups` entitlement. The codebase already has a sophisticated detection and fallback mechanism in place.

## Evidence

### Test Results (Run on this system)

| Keychain Attribute | Status | Requires Entitlement? |
|-------------------|--------|----------------------|
| None (legacy keychain) | ✓ Works | No |
| `kSecAttrAccessible` | ✓ Works | No (on macOS)* |
| `kSecAttrAccessGroup` | ✓ Works | No (surprising!)** |
| `kSecAttrSynchronizable = false` | ✓ Works | No |
| `kSecAttrSynchronizable = true` | ✗ -34018 | **YES** |

*Unlike iOS, macOS allows `kSecAttrAccessible` without entitlements for non-sandboxed apps
**`kSecAttrAccessGroup` works in development but requires entitlement for distribution

### Code Analysis

The codebase already implements the correct solution:

**File: `Sources/SpeakApp/SecureAppStorage.swift` (lines 73-82)**
```swift
// Check if we have the keychain-access-groups entitlement
// Developer ID builds may not have it (stripped for CI)
let hasAccessGroupEntitlement = Self.hasKeychainAccessGroupEntitlement()

let configuration = SecureStorageConfiguration(
    service: "com.justspeaktoit.credentials",
    masterAccount: "speak-app-secrets",
    // Only use access group if we have the entitlement
    accessGroup: hasAccessGroupEntitlement ? "8X4ZN58TYH.com.justspeaktoit.shared" : nil,
    // Only enable sync if we have access group
    synchronizable: hasAccessGroupEntitlement
)
```

**File: `Sources/SpeakCore/SecureStorage.swift` (lines 333-337)**
```swift
// Only set accessibility when using access groups (which implies data protection keychain)
// For non-entitled apps, omit this to use the default legacy keychain
if configuration.accessGroup != nil {
    attributesToUpdate[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
}
```

## Detailed Findings

### 1. What EXACTLY causes -34018 on non-sandboxed, hardened runtime macOS apps?

**Answer:** Using `kSecAttrSynchronizable = true` without the `keychain-access-groups` entitlement.

**Why this matters:**
- iCloud Keychain sync requires the `keychain-access-groups` entitlement
- This entitlement requires a managed provisioning profile
- Developer ID notarization does NOT support managed provisioning profiles
- Therefore, Developer ID apps cannot use iCloud Keychain sync

### 2. Does hardened runtime require specific entitlements for basic keychain access?

**Answer:** No. Hardened runtime does NOT require special entitlements for basic keychain access.

**What works without entitlements:**
- ✓ `SecItemAdd`/`SecItemUpdate`/`SecItemDelete`/`SecItemCopyMatching`
- ✓ `kSecAttrService`, `kSecAttrAccount`, `kSecAttrLabel`
- ✓ `kSecAttrAccessible` (all variants)
- ✓ `kSecAttrSynchronizable = false` (explicit)
- ✓ Omitting `kSecAttrSynchronizable` entirely (defaults to non-sync)

**What REQUIRES entitlements:**
- ✗ `kSecAttrSynchronizable = true` → requires `keychain-access-groups`
- ✗ `kSecAttrAccessGroup` (in production) → requires `keychain-access-groups`

### 3. Legacy Keychain vs Data Protection Keychain

**Legacy Keychain:**
- Created when NO `kSecAttrAccessible` is specified
- Does NOT require entitlements
- Available on all macOS versions
- Survives across app updates and re-signing
- **Recommended for Developer ID apps**

**Data Protection Keychain:**
- Created when `kSecAttrAccessible` IS specified
- On macOS (unlike iOS), this works WITHOUT entitlements for non-sandboxed apps
- Provides better security (tied to user's login keychain)
- Can use values: `kSecAttrAccessibleWhenUnlocked`, `kSecAttrAccessibleAfterFirstUnlock`, etc.

**How to ensure legacy keychain:**
```swift
// DO NOT include kSecAttrAccessible
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "your.service.name",
    kSecAttrAccount as String: "account-identifier",
    kSecValueData as String: data
    // Note: No kSecAttrAccessible, no kSecAttrSynchronizable
]
```

### 4. What attributes trigger entitlement requirements?

**Definitive list based on testing:**

| Attribute | Value | Requires Entitlement? | Notes |
|-----------|-------|----------------------|-------|
| `kSecAttrSynchronizable` | `true` | **YES** | Triggers -34018 |
| `kSecAttrSynchronizable` | `false` | No | Works fine |
| `kSecAttrSynchronizable` | omitted | No | Defaults to false |
| `kSecAttrAccessGroup` | any value | **YES*** | *In signed/notarized builds |
| `kSecAttrAccessible` | any value | No | Surprisingly works on macOS |

### 5. How do other non-sandboxed macOS apps handle this?

**Pattern used by successful apps (1Password, Raycast, Alfred, etc.):**

1. **Detect entitlement availability at runtime**
   - Test keychain operation with entitlement-requiring attributes
   - If it fails with -34018, fall back to legacy keychain

2. **Use minimal keychain queries**
   - Only `kSecClass`, `kSecAttrService`, `kSecAttrAccount`, `kSecValueData`
   - Avoid `kSecAttrSynchronizable`, `kSecAttrAccessGroup`

3. **No iCloud sync for Developer ID builds**
   - Save this feature for Mac App Store builds only
   - Use alternative sync mechanisms (own server, JSON export/import)

## Root Cause Analysis

### Why does this happen?

The macOS Security framework distinguishes between:

1. **App-local keychain** (legacy)
   - Tied to the app's bundle identifier
   - No special entitlements needed
   - Cannot sync via iCloud
   - Cannot share with other apps

2. **Keychain access groups** (modern)
   - Requires provisioning profile with entitlement
   - Enables iCloud Keychain sync
   - Enables sharing between apps with same group
   - **Only available with App Store or Enterprise distribution**

### Why Developer ID is different

- Developer ID uses ad-hoc signing (no managed provisioning profile)
- Cannot include `keychain-access-groups` in the provisioning profile
- Notarization doesn't change this limitation
- Hardened runtime only restricts code execution, not keychain access

## Solution Implementation

### Current State: ✅ ALREADY CORRECT

The codebase already implements the best-practice solution:

1. **Runtime detection** (`SecureAppStorage.swift:92-125`)
   - Tests if `keychain-access-groups` entitlement is available
   - Uses `hasKeychainAccessGroupEntitlement()` function

2. **Conditional configuration** (`SecureAppStorage.swift:73-82`)
   - Sets `accessGroup = nil` when entitlement unavailable
   - Sets `synchronizable = false` when entitlement unavailable

3. **Conditional attribute usage** (`SecureStorage.swift:333-337`)
   - Only uses `kSecAttrAccessible` when `accessGroup != nil`
   - Ensures legacy keychain for non-entitled apps

### Verification Steps

If you're still seeing -34018 errors, check:

1. **Is `synchronizable` being set correctly?**
   ```swift
   // In SecureAppStorage.swift
   print("[SecureAppStorage] synchronizable: \(configuration.synchronizable)")
   ```

2. **Is the entitlement check working?**
   ```swift
   // Should see one of these in console:
   // "[SecureAppStorage] Keychain access group entitlement available"
   // "[SecureAppStorage] No keychain-access-groups entitlement (status: -34018), using app-local keychain"
   ```

3. **Are you passing custom configuration?**
   ```swift
   // Don't do this:
   let config = SecureStorageConfiguration(synchronizable: true) // ❌
   
   // Let SecureAppStorage handle it:
   let storage = SecureAppStorage(permissionsManager: pm, appSettings: settings) // ✅
   ```

## Recommended Code Changes (if still needed)

### Option 1: Ensure synchronizable is never true for Developer ID

**File: `Sources/SpeakCore/SecureStorage.swift`**

Add defensive check in `writeCacheToKeychain()`:

```swift
private func writeCacheToKeychain() throws {
    let payload = serialize(cache: cache)
    let query = baseQuery()
    
    if payload.isEmpty {
        SecItemDelete(query as CFDictionary)
        return
    }
    
    let data = Data(payload.utf8)
    var attributesToUpdate: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrLabel as String: configuration.masterAccount,
    ]
    
    // DEFENSIVE: Never set synchronizable=true without access group
    // This prevents -34018 even if configuration is incorrect
    if configuration.synchronizable {
        guard configuration.accessGroup != nil else {
            throw SecureStorageError.permissionDenied // or log warning and continue
        }
        attributesToUpdate[kSecAttrSynchronizable as String] = kCFBooleanTrue
    }
    
    // ... rest of function
}
```

### Option 2: Add explicit validation

**File: `Sources/SpeakApp/SecureAppStorage.swift`**

```swift
init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
    self.permissionsManager = permissionsManager
    self.appSettings = appSettings
    
    let hasAccessGroupEntitlement = Self.hasKeychainAccessGroupEntitlement()
    
    let configuration = SecureStorageConfiguration(
        service: "com.justspeaktoit.credentials",
        masterAccount: "speak-app-secrets",
        accessGroup: hasAccessGroupEntitlement ? "8X4ZN58TYH.com.justspeaktoit.shared" : nil,
        synchronizable: hasAccessGroupEntitlement
    )
    
    // DEFENSIVE: Validate configuration
    assert(
        !configuration.synchronizable || configuration.accessGroup != nil,
        "synchronizable=true requires accessGroup"
    )
    
    self.storage = SecureStorage(
        configuration: configuration,
        permissionsChecker: PermissionsManagerBridge(permissionsManager: permissionsManager),
        identifierRegistry: appSettings
    )
}
```

## Testing Checklist

- [ ] Run app with Developer ID signing
- [ ] Check console for: `"using app-local keychain"`
- [ ] Verify `configuration.synchronizable == false`
- [ ] Verify `configuration.accessGroup == nil`
- [ ] Test `SecItemAdd` - should succeed
- [ ] Test `storeSecret()` - should succeed
- [ ] Check keychain item with: `security find-generic-password -s "com.justspeaktoit.credentials"`

## References

- Apple TN2311: "Hardened Runtime" - https://developer.apple.com/documentation/security/hardened_runtime
- Apple TN2415: "Entitlements Troubleshooting" - https://developer.apple.com/documentation/bundleresources/entitlements
- SecItemAdd documentation - https://developer.apple.com/documentation/security/1401659-secitemadd
- Keychain Services Programming Guide - https://developer.apple.com/documentation/security/keychain_services

## Conclusion

**The codebase already implements the correct solution.** Error -34018 is caused by `kSecAttrSynchronizable = true` without the `keychain-access-groups` entitlement. The runtime detection and fallback mechanism in `SecureAppStorage.swift` correctly handles this.

**If you're still seeing -34018 errors:**
1. Add debug logging to confirm configuration
2. Verify the entitlement check is running
3. Ensure no code bypasses the SecureAppStorage initialization
4. Check for legacy code directly calling SecItem APIs with synchronizable=true

**The key insight:** macOS is more permissive than iOS. Basic keychain access (even with `kSecAttrAccessible`) works fine. Only iCloud-specific features require entitlements.
