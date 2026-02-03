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

1. **Check current version**: `gh release list | grep mac-v | head -1`
2. **Commit changes** with `[mac]` tag: `git commit -m "feat: [mac] description"`
3. **Push to main**: `git push origin main`
4. **Create and push tag**: 
   ```bash
   git tag mac-v0.7.7  # Use NEXT version after latest mac-v* tag
   git push origin mac-v0.7.7
   ```
5. The workflow builds, notarizes, and publishes to GitHub Releases + updates appcast.xml

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
- Use Conventional Commits (`feat:`, `fix:`, `chore:`) with imperative descriptions
- Keep commits scoped to a single concern
- Pull requests should describe motivation, note user-visible changes, and reference related issues
- Include `make test` output or screenshots when UI shifts

## Security & Configuration Tips
- Do not commit personalised signing assets
- Keep bundle identifiers within `Config/AppInfo.plist` and adjust via scripts
- API keys stored in Keychain via `SecureStorage` (SpeakCore) / `SecureAppStorage` (SpeakApp)
- Keychain service: `com.github.speakapp.credentials`, account: `speak-app-secrets`
