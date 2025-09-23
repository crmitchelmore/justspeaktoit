# Repository Guidelines

## Project Structure & Module Organization
- `Sources/` contains the SwiftUI application code; `SpeakApp.swift` is the main entry point airing the default window.
- `Tests/` holds the XCTest suite (`SpeakAppTests.swift`) that exercises SwiftUI views through composability checks.
- `Config/AppInfo.plist` centralizes bundle metadata. Update via version scripts rather than editing by hand.
- `scripts/version.sh` manages semantic version and build number updates, keeping `VERSION` and `BUILD` in sync.

## Build, Test, and Development Commands
- `make` or `make run` builds (debug) and launches the app with the SwiftPM toolchain.
- `make build` performs a debug compilation only; inspect `.build/debug/SpeakApp` afterwards.
- `make rebuild` cleans previous artefacts then rebuilds from scratch for a fresh baseline.
- `make test` executes the XCTest target; add specs before modifying shared behaviour.
- `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp` runs the lint profile; pair it with SwiftFormat using the analogous command when curating patches.

## Coding Style & Naming Conventions
- Swift files use 4-space indentation and LF line endings (configured via `.swiftformat`).
- Prefer expressive type names (`ContentView`, `SpeakApp`) and keep new API surface internal unless exposure is required.
- Enforce linting via `.swiftlint.yml`; rules include `explicit_self`, `implicit_return`, and line-length 120/160 warnings.

## Testing Guidelines
- Tests live under `Tests/SpeakAppTests` and rely on XCTest. Name specs `test<Behaviour>_<Expectation>()` to mirror scenarios.
- Run `make test` locally before PRs; acceptance checks currently ensure SwiftUI views compose without runtime crashes.

## Commit & Pull Request Guidelines
- Use Conventional Commits (`feat:`, `fix:`, `chore:`) with imperative descriptions. Keep commits scoped to a single concern.
- Pull requests should describe motivation, note user-visible changes, and reference related issues. Include `make test` output or screenshots when UI shifts.

## Security & Configuration Tips
- Do not commit personalised signing assets. Keep bundle identifiers within `Config/AppInfo.plist` and adjust via scripts to preserve consistency.
