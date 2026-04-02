# Repository Context

<!-- changelog: 2026-04-02 — full refresh; added tech stack, module structure, data/auth, deployment, agentic system sections -->

## Durable facts for this role
- Just Speak to It is a SwiftUI voice-transcription product spanning macOS and iOS, with macOS as the richer primary surface.
- Core user moments are capture, live transcript, post-processing, smart output, and history/settings review.
- Privacy-sensitive: supports on-device Apple Speech and explicit user control of cloud providers (AssemblyAI, Deepgram, RevAI).
- Users manage API keys locally; features should not assume app-managed accounts or hidden back-end state.
- Platform scope matters: hotkeys and accessibility-driven output are macOS-specific; iOS has different constraints.
- Good product issues should name the platform, the user moment, and whether the value is privacy, speed, accuracy, or workflow convenience.

## Technology stack
- **Language**: Swift (swift-tools-version 5.9)
- **UI framework**: SwiftUI
- **Minimum platforms**: macOS 14, iOS 17
- **Key dependencies**:
  - Sparkle 2.6.0+ — macOS auto-update (appcast.xml-based)
  - Sentry 9.3.0+ — error monitoring (EU region, org: tally-lz)
  - SwiftLint 0.55.0+ / SwiftFormat 0.53.6+ — code quality
- **Build toolchain**: SwiftPM (primary), Tuist (Xcode project generation), Xcode

## Module structure
| Target | Type | Platform | Purpose |
|---|---|---|---|
| `SpeakCore` | Library | macOS + iOS | Shared types, protocols, Keychain storage |
| `SpeakApp` | Executable | macOS 14 | Full macOS SwiftUI app |
| `SpeakiOSLib` | Library | iOS 17 | iOS views + services (path: Sources/SpeakiOS) |
| `SpeakSync` | Library | macOS + iOS | History sync engine (iCloud-backed) |
| `SpeakHotKeys` | Library | macOS | Global hotkey support |
| `SpeakHotKeysDemo` | Executable | macOS | Dev demo for hotkeys |

- `SpeakiOSApp/` — iOS `@main` entry point (outside Swift package)
- `Tests/SpeakCoreTests`, `Tests/SpeakAppTests` — XCTest suites
- `landing-page/` — static marketing site (deploys to Cloudflare Pages)

### Key source files (macOS)
- `TranscriptionManager.swift` — AssemblyAI live controller, turn handling
- `PostProcessingManager.swift` — LLM post-processing
- `HUDManager.swift / HUDView.swift` — capture health HUD
- `SmartTextOutput / TextOutput.swift` — accessibility insertion
- `TranscriptionProviderRegistry.swift` — provider plug-in system
- `WireUp.swift` — dependency wiring at startup

## Data and auth
- **Keychain**: `SecureStorage` (SpeakCore) and `SecureAppStorage` (SpeakApp) — service `com.github.speakapp.credentials`
- **Transcription providers**: AssemblyAI (WebSocket streaming v3), Deepgram, RevAI, Apple Speech (on-device)
- **Persistence**: UserDefaults / AppSettings for preferences; SpeakSync for history (iCloud container `iCloud.com.justspeaktoit.ios`)
- **Error monitoring**: Sentry (DSN in `SentryManager.swift`); auth token in CI secret `SENTRY_AUTH_TOKEN`
- **App Group**: `group.com.justspeaktoit.ios` (shared between app and widget)

## Deployment
- **macOS**: Fully automated — conventional commits on `main` → `auto-release.yml` → `mac-v*` tag → `release-mac.yml` (build, notarise, GitHub Release, appcast.xml, Homebrew tap)
- **iOS TestFlight**: Manual workflow dispatch (`release-ios.yml`)
- **iOS App Store**: Separate `release-appstore.yml`
- **Landing page**: `deploy-landing-page.yml` — Cloudflare Pages, triggers on `landing-page/**` changes to `main`
- **Current VERSION file**: 0.18.5 (hint only; tag is source of truth)
- **Tag formats**: `mac-v*` (macOS releases), `ios-v*` (iOS releases)

### CI pipeline
- `ci.yml` — build + lint + test on PRs
- `codeql.yml` — security scanning
- `verify-basics` — sanity checks

## Agentic system
**Active daily agents** (all run on schedule, produce issues/PRs automatically):
- `daily-test-improver` — adds XCTest cases
- `daily-perf-improver` — performance micro-optimisations
- `daily-doc-updater` — documentation updates
- `daily-repo-status` — repo health status issues
- `improvement-coordinator` — orchestrates improvement agents
- `repository-quality-improver` — code quality improvements
- `agentics-maintenance` — maintains agentic workflow files
- `stale-issue-cleanup` — closes stale issues
- `ci-doctor` — diagnoses CI failures
- `repository-context-refresh` — updates this file

**PR review agents**: architecture, design, performance, product, quality, security, reliability reviewers active on PRs.

**Planning role memory**: stored in `planning/product` branch; this file is `/tmp/gh-aw/repo-memory/default/planning/product/repository-context.md`.

**Product planning note**: Treat agentic-workflow automation issues as out of scope for product planning validation. Focus on human-authored feature/bug reports.
