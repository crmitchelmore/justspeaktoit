# Repository Context

<!-- changelog: 2026-04-09 — updated latest release to mac-v0.29.2; added OpenClaw, TTS, Transport, PersonalLexicon, LivePolish, Deepgram-iOS entries; expanded SpeakCore module notes -->

## Durable facts for this role
- SwiftUI voice-transcription product (macOS primary, iOS expanding). Core moments: capture → live transcript → post-process → smart output → history + OpenClaw AI chat (iOS).
- Privacy-sensitive: on-device Apple Speech + user-controlled cloud (AssemblyAI, Deepgram, RevAI, OpenAI, Modulate). API keys stored locally in Keychain.
- Platform scope: hotkeys and accessibility output are macOS-only; OpenClaw hands-free and Deepgram live are iOS-specific.
- Good issues name the platform, user moment, and value dimension (privacy / speed / accuracy / workflow).

## Technology stack
- Swift (swift-tools-version 5.9), SwiftUI; macOS 14+, iOS 17+
- Sparkle 2.6.0+ (auto-update), Sentry 9.3.0+ (EU, org: tally-lz), SwiftLint 0.55.0+, SwiftFormat 0.53.6+
- Build: SwiftPM primary; Tuist for Xcode project generation

## Module structure
- `SpeakCore` — macOS+iOS: shared types, protocols, Keychain, OpenClaw client, LLM abstractions, DeepgramLiveClient
- `SpeakApp` — macOS 14 executable: full SwiftUI app
- `SpeakiOSLib` — iOS 17 library: views + services (Sources/SpeakiOS)
- `SpeakSync` — macOS+iOS: iCloud history sync
- `SpeakHotKeys` — macOS: global hotkeys; `SpeakiOSApp/` — iOS `@main` (outside package)
- Tests: `SpeakCoreTests`, `SpeakAppTests`; `landing-page/` — Cloudflare Pages

### Notable source areas
- **macOS**: `TranscriptionManager`, `PostProcessingManager`, `HUDView`, `TextOutput`, `WireUp`, `Transport/TransportServer`, `TextToSpeech/`, `LivePolishManager`, `PersonalLexiconService`
- **iOS**: `OpenClawChatCoordinator[+HandsFree]`, `iOSLiveTranscriber`, `DeepgramLiveTranscriber`, `SendToMacService`
- **SpeakCore**: `OpenClawClient`, `DeepgramLiveClient`, `LLMProtocols/ModelCatalog`, `SecureStorage`, `TranscriptionActivityAttributes`

## Data and auth
- **Keychain**: `SecureStorage` (SpeakCore) / `SecureAppStorage` (SpeakApp) — service `com.github.speakapp.credentials`
- **Transcription**: AssemblyAI (WebSocket v3), Deepgram (live+REST), RevAI, OpenAI Whisper, Modulate, Apple Speech
- **TTS**: System, Deepgram, Azure, ElevenLabs, OpenAI — all via `TTSProtocol`
- **OpenClaw**: AI chat via `OpenClawClient`; iOS hands-free loop; Mac↔iOS via `SendToMacService`/`TransportServer`
- **Persistence**: UserDefaults/AppSettings; SpeakSync history (iCloud `iCloud.com.justspeaktoit.ios`)
- **Error monitoring**: Sentry EU (org: tally-lz, `SentryManager.swift`); CI secret: `SENTRY_AUTH_TOKEN`
- **App Group**: `group.com.justspeaktoit.ios`

## Deployment
- **macOS**: automated — conventional commits → `auto-release.yml` → `mac-v*` tag → `release-mac.yml` (build, notarise, GitHub Release, appcast, Homebrew)
- **iOS TestFlight**: manual dispatch (`release-ios.yml`); App Store: `release-appstore.yml`
- **Landing page**: `deploy-landing-page.yml` — Cloudflare Pages on `landing-page/**` changes
- **Latest release**: mac-v0.29.2 (2026-03-26); VERSION file 0.18.5 is stale hint; tag is source of truth
- **CI**: `ci.yml` (build+lint+test), `codeql.yml` (security), `verify-basics`

## Agentic system
**Active daily agents**: `daily-test-improver`, `daily-perf-improver`, `daily-doc-updater`, `daily-repo-status`, `improvement-coordinator`, `repository-quality-improver`, `agentics-maintenance`, `stale-issue-cleanup`, `ci-doctor`, `repository-context-refresh`.

**PR review agents**: architecture, design, performance, product, quality, security, reliability reviewers active on PRs.

**Planning role memory**: stored in `planning/product` branch; this file is `/tmp/gh-aw/repo-memory/default/planning/product/repository-context.md`.

**Product planning note**: Treat agentic-workflow automation issues as out of scope for product planning validation. Focus on human-authored feature/bug reports.
