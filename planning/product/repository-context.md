# Repository Context

<!-- Updated: 2026-04-09 -->

## Product overview
SwiftUI voice-transcription app. macOS primary, iOS expanding. Core: capture → live transcript → post-process → smart output → history + OpenClaw AI chat (iOS).

## Platforms & modules
- `SpeakApp` (macOS 14+), `SpeakiOSLib` (iOS 17+), `SpeakCore` (shared), `SpeakSync` (iCloud history), `SpeakHotKeys` (macOS hotkeys)
- Good issues name the platform, user moment, and value dimension

## Transcription engines
AssemblyAI (WebSocket v3), Deepgram (live+REST), RevAI, OpenAI Whisper, Modulate, Apple Speech. API keys in Keychain.

## Data & auth
- `SecureStorage` (SpeakCore) / `SecureAppStorage` (SpeakApp); service `com.github.speakapp.credentials`
- History sync: iCloud `iCloud.com.justspeaktoit.ios`; Sentry EU (org: tally-lz)

## Deployment
- macOS: conventional commits → `auto-release.yml` → `mac-v*` tag → build/notarise/release. Latest: mac-v0.29.2
- iOS TestFlight: manual dispatch (`release-ios.yml`)
- CI: `ci.yml` (build+lint+test), `codeql.yml`, `verify-basics`

## Agentic system
Daily bots: test-improver, perf-improver, doc-updater, repo-status, improvement-coordinator. Bot-authored issues are out of product planning scope — noop.

## Key source areas
- macOS: `TranscriptionManager`, `PostProcessingManager`, `HUDView`, `TextOutput`, `Transport/TransportServer`, `LivePolishManager`
- iOS: `OpenClawChatCoordinator[+HandsFree]`, `iOSLiveTranscriber`, `DeepgramLiveTranscriber`
- Shared: `OpenClawClient`, `DeepgramLiveClient`, `LLMProtocols/ModelCatalog`
