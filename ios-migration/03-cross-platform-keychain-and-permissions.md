# 03 — Cross-platform Keychain + Permissions Abstractions

## Goal
Make secrets storage and permission gating work on both macOS and iOS, without breaking existing behavior.

## Scope
- Introduce small abstractions so `SpeakCore` can compile on iOS.
- Keep the keychain schema consistent across platforms.

## Steps
1. In `SpeakCore`, define protocols:
   - `PermissionsChecking` (microphone, speech recognition, keychain access where applicable)
   - `SecureSecretsStoring` (store/secret/remove/knownIdentifiers/hasSecret)
2. Move current `SecureAppStorage` into `SpeakCore` if possible.
   - Use `kSecAttrAccessGroup` (shared group) behind a configuration value.
   - Prepare for `kSecAttrSynchronizable` on iOS/macOS.
3. Add platform-specific permission helpers:
   - iOS: `AVAudioSession.recordPermission`, `SFSpeechRecognizer.requestAuthorization`
   - macOS: keep current flows
4. Ensure existing macOS app behavior is unchanged.

## Deliverables
- `SpeakCore` compiles for macOS and iOS (even if iOS app target isn’t added yet).
- A single consolidated keychain item remains the canonical storage.

## Acceptance criteria
- `make build && make test` still succeed.
- The keychain serialization format is unchanged.

---

## ✅ Complete (2026-01-08)

### Changes made
1. Created `Sources/SpeakCore/SecureStorage.swift`:
   - `SecureStorage` actor — cross-platform keychain storage
   - `SecureStorageConfiguration` — service/account/accessGroup/synchronizable
   - `SecureStorageError` — error types
   - `KeychainPermissionsChecking` protocol — abstraction for permission checks
   - `APIKeyIdentifierRegistry` protocol — for registering keys with app settings
   - `DefaultKeychainPermissions` — default implementation

2. Refactored `SecureAppStorage` in SpeakApp:
   - Now a thin wrapper around `SecureStorage`
   - `PermissionsManagerBridge` adapts `PermissionsManager` to protocol
   - `AppSettings` conforms to `APIKeyIdentifierRegistry`
   - Same public API preserved for backward compatibility

3. Keychain schema unchanged:
   - Service: `com.github.speakapp.credentials`
   - Account: `speak-app-secrets`
   - Payload: semicolon-delimited `NAME=value`

4. Cross-platform support ready:
   - `accessGroup` parameter for keychain sharing
   - `synchronizable` parameter for iCloud Keychain sync

### Build/Test
- `make build` — **PASS**
- `make test` — **PASS** (4 tests, 0 failures)
