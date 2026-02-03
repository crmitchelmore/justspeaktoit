# Security Fix: Move Pairing Codes from UserDefaults to Keychain

## Overview
This fix addresses a security vulnerability where pairing codes (authentication secrets) were stored in UserDefaults, which is readable by any local process on the same user account.

## Security Classification

### CRITICAL (Moved to Keychain)
- **Pairing code**: 6-digit authentication secret used to pair iOS and macOS devices

### LOW (Remains in UserDefaults)
- **Device names**: Non-sensitive metadata (e.g., "John's iPhone")
- **Device IDs**: Non-sensitive public identifiers (e.g., UUID strings)

## Changes Made

### 1. `Sources/SpeakCore/TransportProtocol.swift`

**PairingManager Class Modifications:**
- Changed `pairingCode` to async computed property that reads from Keychain
- Changed `regeneratePairingCode()` to async function  
- Changed `validatePairingCode(_:)` to async function
- Added `SecureStorage` instance for Keychain access
- Added migration logic to move existing codes from UserDefaults to Keychain
- Added caching to minimize Keychain reads
- Device names and IDs remain in UserDefaults (non-sensitive)

**Key Implementation Details:**
- Keychain identifier: `"speakTransportPairingCode"`
- Migration runs once on first access
- After migration, UserDefaults entry is deleted
- Falls back to generating new code if none exists in either storage

### 2. `Sources/SpeakApp/SettingsView.swift`

**UI Updates:**
- Added `@State private var currentPairingCode: String` to hold async-loaded code
- Added `.task` modifier to load pairing code when view appears
- Updated button action to use `Task { await ... }` for regeneration
- Updated copy-to-clipboard to use state variable

### 3. `Sources/SpeakApp/Transport/TransportServer.swift`

**Authentication Flow:**
- Updated `handleAuthentication()` to await validation:  
  `let isValid = await PairingManager.shared.validatePairingCode(auth.pairingCode)`

### 4. `Tests/SpeakCoreTests/PairingManagerTests.swift` (New File)

**Test Coverage:**
- Code generation format validation (6 digits)
- Code persistence across multiple reads
- Valid/invalid code validation
- Code regeneration produces new code
- Paired device CRUD operations
- Paired devices cleared on regeneration
- Migration scenario documentation

## Security Benefits

1. **Defense in Depth**: Pairing codes now protected by macOS Keychain access controls
2. **Least Privilege**: Only the app (and authorized keychain-access-group members) can read codes
3. **Zero Trust**: Assuming UserDefaults is compromised, pairing codes remain secure
4. **Backward Compatibility**: Automatic migration preserves existing pairings

## Migration Strategy

On first run after update:
1. Check UserDefaults for legacy pairing code
2. If found and Keychain empty, move code to Keychain
3. Delete code from UserDefaults
4. Cache in memory for performance

## Verification Steps

1. Build the project: `make build`
2. Run tests: `make test`
3. Manual test:
   - Launch macOS app
   - Check Settings > General > Send to Mac
   - Verify pairing code displays
   - Click "Copy" button - verify code copies
   - Click "Regenerate Code" - verify new code appears
   - On iOS app, attempt pairing with code
   - Verify successful authentication

## Files Modified

- `Sources/SpeakCore/TransportProtocol.swift` - Core pairing manager logic
- `Sources/SpeakApp/SettingsView.swift` - UI for displaying/managing pairing code
- `Sources/SpeakApp/Transport/TransportServer.swift` - Server-side authentication
- `Tests/SpeakCoreTests/PairingManagerTests.swift` - Unit tests (new file)

## Compliance Impact

- ✅ Addresses CWE-522: Insufficiently Protected Credentials
- ✅ Aligns with OWASP Mobile Top 10 - M2: Insecure Data Storage
- ✅ Meets Apple Keychain Services best practices

## Rollback Plan

If issues arise:
1. Revert `TransportProtocol.swift` to sync (non-async) version
2. Restore UserDefaults storage
3. Codes will regenerate on next use (existing pairings invalidated)

## Future Enhancements

1. Consider adding biometric protection (Touch ID/Face ID) to Keychain items
2. Add rotation policy (e.g., expire codes after 30 days)
3. Add audit logging for pairing events
4. Consider adding TOTP-style time-based codes for additional security

---
**Author**: Security Agent  
**Date**: 2024-02-03  
**Issue**: Store pairing codes in Keychain instead of UserDefaults  
**PR**: To be created on branch `fix/pairing-codes-keychain`
