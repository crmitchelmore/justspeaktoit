# Repository Guidelines

## Versioning & Release Process

This project maintains **separate version tracks** for macOS and iOS:

### Version Discovery

**CRITICAL: Always check the ACTUAL latest release before creating a new version.**

```bash
# Find the latest macOS release version:
gh release list --repo crmitchelmore/justspeaktoit | grep "mac-v" | head -1

# Or check GitHub releases page for mac-v* tags
# Example: if latest is mac-v0.9.1 → next should be mac-v0.9.2

# The VERSION file is NOT authoritative for releases - always check GitHub tags
```

### Tag Conventions

| Platform | Tag Format | Example | Workflow Triggered |
|----------|------------|---------|-------------------|
| macOS | `mac-v*` | `mac-v0.7.7` | `.github/workflows/release-mac.yml` |
| iOS | `ios-v*` | `ios-v0.9.1` | `.github/workflows/release-ios.yml` (manual) |
| Legacy | `v*` | `v0.7.5` | None (deprecated) |

### macOS Release Process

Releases are **fully automated** via conventional commits:

1. Push to `main` with a releasable commit type (`feat:`, `fix:`, `perf:`, or breaking change)
2. `auto-release.yml` determines the version bump and creates a `mac-v*` tag
3. `release-mac.yml` builds, notarises, publishes to GitHub Releases, updates appcast.xml, and updates Homebrew tap

Manual releases are still possible by creating and pushing a `mac-v*` tag directly.

### iOS Release Process

1. iOS uses **manual workflow dispatch** (not tag-triggered)
2. Go to Actions → "Release iOS (TestFlight)" → Run workflow
3. Enter version number (check App Store Connect for current version)

### VERSION File

The `VERSION` file is a **hint** used as fallback when no tag is present. It does NOT control the release version - the **tag determines the version**. Keep it updated but always verify against actual releases.

## Project Structure & Module Organization

This project uses **Swift Package Manager** for modularization with cross-platform support:

```
Package.swift           # Defines all targets and dependencies
Sources/
├── SpeakCore/          # Shared cross-platform library (types, protocols, keychain)
├── SpeakApp/           # macOS application (executable)
└── SpeakiOS/           # iOS library (views, services, with #if os(iOS) guards)
SpeakiOSApp/            # iOS app entry point (@main)
Project.swift           # Tuist manifest (Xcode project generation)
Workspace.swift         # Tuist workspace manifest
Just Speak to It.xcodeproj/ # Generated Xcode project
Tests/                  # XCTest suite
```

### Swift Package Targets

| Target | Type | Platform | Description |
|--------|------|----------|-------------|
| `SpeakCore` | Library | macOS + iOS | Cross-platform types, protocols, secure storage |
| `SpeakApp` | Executable | macOS | macOS SwiftUI application |
| `SpeakiOSLib` | Library | iOS | iOS views and services (exported with `public` APIs) |

### Modularization Patterns

1. **Shared code in SpeakCore**: Types, protocols, and utilities that work on both platforms
2. **Platform guards**: Use `#if os(iOS)` / `#if os(macOS)` for platform-specific code
3. **Public APIs for libraries**: Types in `SpeakiOSLib` must be `public` for Xcode project to access
4. **Tuist links packages**: `Project.swift` references the local Swift package for Xcode generation

### iOS App Structure

The iOS app is built via Xcode but sources come from Swift packages:
- `SpeakiOSApp/SpeakiOSApp.swift` - Entry point with `@main`
- Links `SpeakCore` and `SpeakiOSLib` as package dependencies
- Run `tuist generate` and open `"Just Speak to It.xcworkspace"` in Xcode to build/run on device

## Build, Test, and Development Commands

### macOS (SwiftPM)
- `make` or `make run` – Build and launch the macOS app
- `make build` – Debug compilation only
- `make rebuild` – Clean and rebuild from scratch
- `make test` – Execute XCTest suite
- `swift build --target SpeakiOSLib` – Verify iOS library compiles

### iOS (Xcode)
- `tuist generate` – Generate the Xcode workspace
- `open "Just Speak to It.xcworkspace"` – Open in Xcode
- Select device/simulator and build (Cmd+B)
- Or use xcodebuild MCP for automation (see below)

### Linting
```bash
swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp
swift package plugin --allow-writing-to-package-directory swiftformat --target SpeakApp
```

## MCP Tools

### xcodebuild MCP
Installed globally via npm for Xcode build automation:
```bash
npm install -g xcodebuildmcp
```

The MCP server provides tools for:
- Project/workspace discovery
- Building for iOS/macOS targets
- Simulator management
- App deployment and testing

### Usage Pattern
When xcodebuild MCP is available, prefer it for:
- Automated iOS builds without opening Xcode
- CI/CD pipeline integration
- Simulator lifecycle management

## Design Patterns

### Liquid Glass (iOS 26+)
See `.copilot/skills/liquid-glass.md` for Apple's Liquid Glass design guidance.

Key principles:
- **Glass for controls layer** (toolbars, nav bars, floating controls) - not content
- **System components first** - they apply Liquid Glass automatically
- **Remove custom backgrounds** on navigation chrome
- **SF Symbols** for icon-only controls with accessibility labels
- **Spring animations** for natural motion
- **Tint sparingly** - only for semantic emphasis (critical actions)

### Cross-Platform Code
```swift
// In SpeakCore (shared)
public struct TranscriptionResult: Sendable { ... }

// In SpeakiOS (iOS-only)
#if os(iOS)
public final class iOSLiveTranscriber: ObservableObject { ... }
#endif
```

## Coding Style & Naming Conventions
- Swift files use 4-space indentation and LF line endings (configured via `.swiftformat`)
- Prefer expressive type names (`ContentView`, `SpeakApp`)
- Keep new API surface `internal` unless exposure is required for cross-module use
- Use `public` for types that need to be accessed from Xcode project or other modules
- Enforce linting via `.swiftlint.yml`; rules include `explicit_self`, `implicit_return`, line-length 120/160

## Testing Guidelines
- Tests live under `Tests/SpeakAppTests` and rely on XCTest
- Name specs `test<Behaviour>_<Expectation>()` to mirror scenarios
- Run `make test` locally before PRs
- iOS testing requires device/simulator via Xcode

## Commit & Pull Request Guidelines
- **Use Conventional Commits** — this is mandatory as commit types drive automated releases
- Commit types that **trigger a release**: `feat:` (minor bump), `fix:` / `perf:` (patch bump), breaking changes via `!` suffix or `BREAKING CHANGE` footer (major bump)
- Commit types that **do not release**: `chore:`, `docs:`, `ci:`, `style:`, `test:`, `refactor:`, `build:`
- Keep commits scoped to a single concern
- Use platform tags in scope: `feat(mac):`, `fix(ios):` — these feed Sparkle release notes
- Pull requests should describe motivation, note user-visible changes, and reference related issues
- Include `make test` output or screenshots when UI shifts

### Automated Release Process
- Every push to `main` triggers `.github/workflows/auto-release.yml`
- The workflow analyses conventional commits since the last `mac-v*` tag
- If releasable commits exist, it creates a new `mac-v*` tag which triggers the full macOS build/notarise/release pipeline
- The `VERSION` file is updated as a best-effort side effect; the **tag is the source of truth**
- Non-releasable commits (chore, docs, ci, etc.) do not create a release

### Working with Auto-Release
- After pushing a releasable commit (`feat:`, `fix:`, `perf:`), the bot pushes a VERSION bump commit to main
- You must `git pull --rebase origin main` before your next push, or it will be rejected
- If you have unstaged changes: `git stash && git pull --rebase origin main && git stash pop`

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

### MainActor Deadlock Anti-Pattern
- **Never** use `DispatchSemaphore.wait()` on the MainActor while spawning `Task { @MainActor in }` — this is an instant deadlock
- The semaphore blocks the MainActor, preventing the task from ever executing to signal it
- Use `Thread.sleep` for brief synchronous delays, or restructure as fully `async`

## AssemblyAI Universal Streaming

### Turn message semantics
- With `format_turns=true`, each turn produces TWO end-of-turn messages: unformatted then formatted. Only commit the formatted one.
- `transcript` contains only finalised words (`word_is_final=true`). Non-final words appear only in the `words` array.
- Track `turn_order` to replace (not append) segments for the same turn.
- Interim text uses replacement semantics — AssemblyAI sends the full turn text each time, not deltas.

### Pre-processing prompt
- `postProcessingSystemPrompt` is sent as the `prompt` query parameter on the WebSocket URL when using AssemblyAI.
- When a pre-processing prompt is active, LLM post-processing is automatically skipped.
- `prompt` and `keyterms_prompt` are mutually exclusive — prompt takes priority.

### Key files
- `AssemblyAITranscriptionProvider.swift` — WebSocket client, response models
- `TranscriptionManager.swift` (`AssemblyAILiveController`) — turn handling, audio processing

## Commit Message Tagging
- Prefix commit messages with a platform tag or scope: `[mac]`/`[ios]` or `(mac)`/`(ios)` (e.g., `fix: [mac] add recording sound picker` or `fix(mac): add recording sound picker`).
- These tags/scopes feed the Sparkle release notes generator so macOS updates only list mac-specific changes.

## Security & Configuration Tips
- Do not commit personalised signing assets
- Keep bundle identifiers within `Config/AppInfo.plist` and adjust via scripts
- API keys stored in Keychain via `SecureStorage` (SpeakCore) / `SecureAppStorage` (SpeakApp)
- Keychain service: `com.github.speakapp.credentials`, account: `speak-app-secrets`

## App Store Connect / iOS Signing (sensitive)
- App Store Connect API Key ID: stored in secure notes (do not commit)
- App Store Connect Issuer ID: stored in secure notes (do not commit)
- App Store Connect API key: store base64 in `.env` as `APP_STORE_CONNECT_API_KEY` (do not commit)
- iOS distribution cert: store base64 in `.env` as `IOS_DISTRIBUTION_P12` (password in `.env` as `IOS_DISTRIBUTION_PASSWORD`)
- GitHub secrets used by CI: `APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_ISSUER_ID`, `APPLE_TEAM_ID`, `IOS_DISTRIBUTION_P12`, `IOS_DISTRIBUTION_PASSWORD`, `IOS_APPSTORE_PROFILE`, `IOS_WIDGET_APPSTORE_PROFILE`
- Required entitlements: App Group `group.com.justspeaktoit.ios` and iCloud container `iCloud.com.justspeaktoit.ios`
- Never commit private keys or provisioning profile contents.
