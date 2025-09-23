# SpeakApp

Native macOS SwiftUI starter project with standard tooling and automation to support everyday development and release workflows.

## Prerequisites

- macOS 14 or newer with Xcode 16 (or Swift toolchain 5.9+) installed.
- SwiftPM handles dependencies; no manual installations are required for linting/formatting.

## Key Commands

All automation is exposed via `make` targets. Use `make help` to list them.

- `make` / `make run` – Build if needed and launch the SwiftUI app.
- `make build` – Compile the app in debug configuration.
- `make rebuild` – Clean and then perform a fresh build.
- `make clean` – Remove build artefacts.
- `make test` – Execute the package test suite.

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

## Next Steps

Open the project in Xcode with `xed .` or continue iterating purely with SwiftPM. The root `SpeakApp.swift` contains a “Hello, Speak” window ready for extension.
