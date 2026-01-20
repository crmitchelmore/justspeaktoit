# Just Speak to It

Native macOS and iOS SwiftUI transcription app with modular Swift packages.

## Project Structure

```
Sources/
├── SpeakCore/      # Shared cross-platform library (types, protocols, secure storage)
├── SpeakApp/       # macOS application
└── SpeakiOS/       # iOS library (live transcription, views)
SpeakiOSApp/        # iOS app entry point
Just Speak to It.xcodeproj/ # Generated via Tuist (iOS + macOS)
```

### Swift Packages

- **SpeakCore** - Cross-platform types, protocols, keychain storage, model catalog
- **SpeakiOSLib** - iOS-specific live transcription with Apple Speech, views
- **SpeakApp** - macOS executable

## Prerequisites

- macOS 14 or newer with Xcode 15 (ships Swift toolchain 5.9) or a standalone Swift 5.9+ toolchain installed.
- iOS 17+ for the iOS app
- SwiftPM handles dependencies; no manual installations are required for linting/formatting.

## Key Commands

All automation is exposed via `make` targets. Use `make help` to list them.

- `make` / `make run` – Build if needed and launch the macOS SwiftUI app.
- `make build` – Compile the app in debug configuration.
- `make rebuild` – Clean and then perform a fresh build.
- `make clean` – Remove build artefacts.
- `make test` – Execute the package test suite.

### Building iOS

```bash
# Build SpeakiOSLib (verifies iOS code compiles)
swift build --target SpeakiOSLib

# Generate Xcode project with Tuist
tuist generate
open "Just Speak to It.xcworkspace"
# Select iOS device/simulator and build (Cmd+B)
```

## Versioning

`VERSION` stores the semantic version and `BUILD` tracks the monotonically increasing build number. `scripts/version.sh` keeps them in sync and updates `Config/AppInfo.plist` when present.

Examples:

```bash
./scripts/version.sh bump-version minor
./scripts/version.sh bump-build
./scripts/version.sh show
```

## Tooling

- **SwiftLint** (`.swiftlint.yml`): opinionated linting with opt-in rules commonly used across teams.
- **SwiftFormat** (`.swiftformat`): formatting profile consistent with SwiftUI-style projects.

Run lint/format directly with SwiftPM when needed, for example:

```bash
swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp
swift package plugin --allow-writing-to-package-directory swiftformat --target SpeakApp
```

## Secrets & API Keys

`SecureAppStorage` keeps every secret inside a single Keychain item named `speak-app-secrets` under the service `com.github.speakapp.credentials`. The value is a semicolon-delimited list with `NAME=value` pairs, for example:

```
OPENROUTER_API_KEY=sk-123;REVAI_API_KEY=rv-456
```

On first launch after upgrading to this scheme the app automatically migrates any per-key entries it previously stored into the consolidated record and deletes the legacy items.

You can seed or edit the entry ahead of time with the `security` CLI:

```bash
security add-generic-password \
  -U \
  -a speak-app-secrets \
  -s com.github.speakapp.credentials \
  -w 'OPENROUTER_API_KEY=sk-123;REVAI_API_KEY=rv-456'
```

At launch the app hydrates this blob into memory and serves typed accessors to the rest of the codebase, so end users still interact through the Settings UI while developers can keep credentials consolidated.

## iOS App

The iOS app uses Apple Speech for on-device live transcription:

- **AudioSessionManager** - iOS audio session lifecycle management
- **iOSLiveTranscriber** - SFSpeechRecognizer integration with partial results
- **ContentView** - Start/Stop recording, live transcript display, copy to clipboard

Open `"Just Speak to It.xcworkspace"` in Xcode to build and run on device/simulator.

## Next Steps

Open the project in Xcode with `xed .` or continue iterating purely with SwiftPM. The root `SpeakApp.swift` contains a "Hello, Just Speak to It" window ready for extension.
