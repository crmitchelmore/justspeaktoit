# Just Speak to It

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20iOS-lightgrey.svg)](https://developer.apple.com/swift/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)

Native macOS and iOS voice transcription app built with SwiftUI. Speak naturally and get accurate text - on-device or via cloud APIs.

## Features

- 🎤 **Live transcription** with real-time display
- 🔒 **Privacy-first** - on-device processing available
- ⌨️ **Global hotkey** - start/stop from anywhere
- 📋 **Auto-paste** - transcribed text goes where you need it
- 🎯 **Personal corrections** - teach it your vocabulary
- 📊 **Usage insights** - track your transcription habits

## Quick Start

```bash
# Clone and run (macOS)
git clone https://github.com/chrismitchelmore/just-speak-to-it.git
cd just-speak-to-it
make run
```

That's it! The app will launch and guide you through granting microphone permissions.

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

## Troubleshooting

### Permissions Not Appearing in System Settings

If the app shows permissions as "denied" but doesn't appear in System Settings → Privacy & Security, you may need to reset the TCC (Transparency, Consent, and Control) database:

```bash
# Reset accessibility permission for the app
tccutil reset Accessibility com.justspeaktoit.mac

# Reset microphone permission
tccutil reset Microphone com.justspeaktoit.mac

# Reset input monitoring
tccutil reset ListenEvent com.justspeaktoit.mac
```

After running these commands, restart the app - it will prompt for permissions again.

### Keychain Errors

If you see "A required entitlement isn't present" when saving API keys, this may occur with Developer ID builds from GitHub Releases. The app will automatically fall back to app-local keychain storage (without iCloud sync). This is expected behavior for non-App-Store builds.

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

- 🐛 [Report bugs](https://github.com/chrismitchelmore/just-speak-to-it/issues/new?template=bug_report.md)
- 💡 [Request features](https://github.com/chrismitchelmore/just-speak-to-it/issues/new?template=feature_request.md)
- 📖 [Read the docs](./Docs/)

## License

This project is licensed under the MIT License - see [LICENSE](./LICENSE) for details.
