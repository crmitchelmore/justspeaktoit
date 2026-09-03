# Just Speak to It

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20iOS-lightgrey.svg)](https://developer.apple.com/swift/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Sponsor](https://img.shields.io/badge/sponsor-GitHub%20Sponsors-ea4aaa?logo=github)](https://github.com/sponsors/crmitchelmore)
[![Ko-fi](https://img.shields.io/badge/support-Ko--fi-ff5e5b?logo=ko-fi)](https://ko-fi.com/crmitchelmore)

Native macOS and iOS voice transcription app built with SwiftUI. Speak naturally and get accurate text - on-device or via cloud APIs.

## Features

- 🎤 **Live transcription** with real-time display
- 🔒 **Privacy-first** - on-device processing available
- ⌨️ **Global hotkey** - start/stop from anywhere
- 📋 **Auto-paste** - transcribed text goes where you need it
- 🎯 **Personal corrections** - teach it your vocabulary
- 📊 **Usage insights** - track your transcription habits

## Quick Start

### Homebrew (Recommended)

```bash
brew tap crmitchelmore/justspeaktoit
brew install --cask justspeaktoit
```

Homebrew installs the right build for your Mac automatically, along with the
standalone `speak` automation CLI (`brew install crmitchelmore/justspeaktoit/speak`
installs just the CLI). Direct downloads can add the CLI later from
Settings → General → Automation CLI.

### Direct download

Every release on the [Releases page](https://github.com/crmitchelmore/justspeaktoit/releases/latest) ships two DMGs:

- **Apple Silicon (recommended):** `JustSpeakToIt-arm64.dmg` — the primary download, arm64 only.
- **Intel Macs (legacy):** `JustSpeakToIt-universal.dmg` — a universal build that also runs on Apple Silicon, kept for Intel Macs and for existing installs.

Apple Silicon installs update to arm64-only builds; Intel installs keep receiving the universal build. Both update paths are notarised and signed.

### Build from Source

```bash
# Clone and run (macOS)
git clone https://github.com/crmitchelmore/justspeaktoit.git
cd justspeaktoit
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

- macOS 14 or newer with a current Xcode (Xcode 26.x, Apple Swift 6.2). Build with Xcode's toolchain: standalone swift.org toolchains (for example swiftly's default) do not build this repo today (the snapshot-testing dependency fails to compile and a release build crashes the optimiser in `argmax-oss-swift`, see #877). If `swift --version` does not say `Apple Swift`, run `xcode-select -s /Applications/Xcode.app` or unset `TOOLCHAINS`.
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

`VERSION` is a repository hint and `BUILD` tracks the monotonically increasing build number. `scripts/version.sh` keeps them in sync and updates `Config/AppInfo.plist` when present. For TestFlight, the release workflow requires an explicit iOS version; check App Store Connect rather than relying on `VERSION`. See [the iOS TestFlight release runbook](Docs/ios-testflight-release.md).

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

## Transcription Providers

Just Speak to It supports multiple live and batch transcription backends on macOS and iOS. `Sources/SpeakCore/ModelCatalog.swift` is the canonical source for current built-in model identifiers and display names.

### macOS

- **Live**: Apple Speech (`apple/local/SFSpeechRecognizer`), Apple Dictation (`apple/local/Dictation`), local FluidAudio Parakeet Realtime EOU (`local/streaming/fluidaudio/parakeet-realtime-eou-120m`), Deepgram (`deepgram/nova-3-streaming`, `deepgram/flux-general-en-streaming`, `deepgram/flux-general-multi-streaming`), Cartesia (`cartesia/ink-2-streaming`), Google Gemini 3.5 Transcribe Live (`google/gemini-3.5-transcribe-live`, public preview), Modulate (`modulate/velma-2-stt-streaming`), AssemblyAI (`assemblyai/universal-3-5-pro-streaming`), Soniox (`soniox/stt-rt-v5-streaming`), ElevenLabs Scribe (`elevenlabs/scribe-v2-streaming`), Meta Muse Voice Transcribe (`meta/muse-voice-transcribe-1.0-streaming`), and OpenAI Realtime (`openai/gpt-realtime-whisper-streaming`, `openai/gpt-4o-mini-transcribe-streaming`, `openai/gpt-4o-transcribe-streaming`).
- **Batch**: Meta Muse Voice Transcribe (`meta/muse-voice-transcribe-1.0`), OpenAI Whisper / GPT-4o Transcribe (`openai/whisper-1`, `openai/gpt-4o-mini-transcribe`, `openai/gpt-4o-transcribe`, `openai/gpt-4o-transcribe-diarize`), Groq Whisper (`groq/whisper-large-v3-turbo`), Soniox (`soniox/stt-async-v5`), Rev.ai (`revai/default`), Deepgram (`deepgram/nova-3`), Modulate (`modulate/velma-2-stt-batch`, `modulate/velma-2-stt-batch-english-vfast`), AssemblyAI (`assemblyai/universal-3-5-pro`, `assemblyai/universal-2`), ElevenLabs Scribe (`elevenlabs/scribe_v2`), Google Gemini 3.5 Transcribe (`google/gemini-3.5-transcribe`, public preview), and OpenRouter audio models such as `google/gemini-2.0-flash-001`, `google/gemini-2.0-flash-lite-001`, and `openai/gpt-4o-audio-preview-2024-12-17`.
- **Voice output (TTS)**: ElevenLabs, OpenAI, Azure Cognitive Services, Deepgram Aura (`Sources/SpeakCore/DeepgramTTSCatalog.swift`), Soniox TTS v2 (`tts-rt-v2`, 60+ languages; `Sources/SpeakCore/SonioxTTSCatalog.swift`), Cartesia Sonic 3.6 (macOS; `sonic-3.6` over `/tts/bytes`, `Sources/SpeakCore/CartesiaTTSCatalog.swift`), and macOS system voices. iOS OpenClaw routes Deepgram over REST or Soniox over its region-selected low-latency WebSocket with streaming PCM playback.
- API keys are stored in the Keychain. The ElevenLabs, Soniox and Cartesia keys are each reused across that provider's TTS and transcription models.
- The Parakeet model is downloaded on demand, runs entirely on the Mac through Apache-2.0-licensed FluidAudio/Core ML, supports English, and is distributed under the NVIDIA Open Model License.

### iOS

- **Live**: Apple Speech (`apple/local/SFSpeechRecognizer`), Deepgram (`deepgram/nova-3`), ElevenLabs Scribe (`elevenlabs/scribe-v2-streaming`), and Meta Muse Voice Transcribe (`meta/muse-voice-transcribe-1.0-streaming`).
- **Batch**: Apple Speech Analyzer, direct OpenAI transcription, supported OpenRouter audio models, and Meta Muse Voice Transcribe (`meta/muse-voice-transcribe-1.0`).
- If Deepgram or ElevenLabs is selected without a configured API key, recording falls back to Apple Speech.

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

The iOS app supports multiple live transcription providers:

- **Apple Speech** (on-device, default) — `iOSLiveTranscriber` via `SFSpeechRecognizer` with partial results
- **Deepgram** (cloud) — `DeepgramLiveTranscriber` over WebSocket when a Deepgram key is configured
- **ElevenLabs Scribe** (cloud) — `ElevenLabsLiveTranscriber` over WebSocket when an ElevenLabs key is configured

Key components:

- **AudioSessionManager** - iOS audio session lifecycle management
- **iOSLiveTranscriber** - SFSpeechRecognizer integration with partial results
- **DeepgramLiveTranscriber** - Deepgram live streaming for cloud transcription
- **ElevenLabsLiveTranscriber** - ElevenLabs Scribe live streaming (16 kHz PCM16 over WebSocket)
- **TranscriptionRecordingService** - Provider selection, fallback handling, and recording lifecycle
- **ContentView** - Start/Stop recording, live transcript display, copy to clipboard

The selected transcription model is persisted via `AppSettings`. If Deepgram or ElevenLabs is selected but the corresponding API key is missing, recording falls back to Apple Speech at start time.

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
