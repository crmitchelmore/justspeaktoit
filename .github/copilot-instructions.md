# Copilot Instructions

Project-specific patterns and conventions for AI-assisted development.

## SwiftUI Concurrency Patterns

### Singleton ObservableObjects
- Use `@ObservedObject` (not `@StateObject`) when referencing singletons like `TipStore.shared`
- Singletons manage their own lifecycle; `@StateObject` causes ownership conflicts and crashes

### Child View Button Actions
- Don't pass `@ObservedObject` to child views that have button actions
- Pass primitive values (e.g., `isPurchasing: Bool`) and access singleton directly in action:
  ```swift
  Button {
      Task { @MainActor in
          await MySingleton.shared.doWork()
      }
  }
  ```

### Async Delays in SwiftUI
- Prefer `.task { try? await Task.sleep(for: .seconds(2)) }` over `DispatchQueue.asyncAfter`
- The `.task` modifier properly handles view lifecycle and cancellation

## Commit Message Tagging
- Prefix commit messages with a platform tag or scope: `[mac]`/`[ios]` or `(mac)`/`(ios)` (e.g., `fix: [mac] add recording sound picker` or `fix(mac): add recording sound picker`).
- These tags/scopes feed the Sparkle release notes generator so macOS updates only list mac-specific changes.

## App Store Connect / iOS Signing (sensitive)
- App Store Connect API Key ID: stored in secure notes (do not commit)
- App Store Connect Issuer ID: stored in secure notes (do not commit)
- App Store Connect API key: store base64 in `.env` as `APP_STORE_CONNECT_API_KEY` (do not commit)
- iOS distribution cert: store base64 in `.env` as `IOS_DISTRIBUTION_P12` (password in `.env` as `IOS_DISTRIBUTION_PASSWORD`)
- GitHub secrets used by CI: `APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_ISSUER_ID`, `APPLE_TEAM_ID`, `IOS_DISTRIBUTION_P12`, `IOS_DISTRIBUTION_PASSWORD`, `IOS_APPSTORE_PROFILE`, `IOS_WIDGET_APPSTORE_PROFILE`
- Required entitlements: App Group `group.com.justspeaktoit.ios` and iCloud container `iCloud.com.justspeaktoit.ios`
- Never commit private keys or provisioning profile contents.
