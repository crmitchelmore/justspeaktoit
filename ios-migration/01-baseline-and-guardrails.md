# 01 — Baseline and Guardrails

## Goal
Establish a known-good baseline and define guardrails so the migration doesn’t destabilize the existing macOS app.

## Scope
- Document current build/test commands and expected outcomes.
- Freeze current keychain data format and identifiers.
- Identify files that are macOS-only vs candidates for sharing.

## Steps
1. Run:
   - `make build`
   - `make test`
2. Capture any failures (if any) and decide whether they are pre-existing.
3. Confirm secrets storage scheme in `SecureAppStorage`:
   - service: `com.github.speakapp.credentials`
   - account: `speak-app-secrets`
   - payload format: `NAME=value;NAME=value`
4. Write down the *exact* identifiers currently used for API keys (e.g., `deepgram.apiKey`).

## Deliverables
- A short note appended to this file with:
  - build/test status
  - list of key identifiers used in the app today

## Acceptance criteria
- You can run `make build` and `make test` (or you have documented pre-existing failures).
- Keychain payload format and identifiers are confirmed and unchanged.

---

## ✅ Baseline Results (2026-01-08)

### Build/Test Status
- `make build` — **PASS** (1.92s)
- `make test` — **PASS** (4 tests, 0 failures)

### Keychain Schema
- **Service:** `com.github.speakapp.credentials`
- **Account:** `speak-app-secrets`
- **Payload format:** semicolon-delimited `NAME=value` pairs

### API Key Identifiers Currently Used
| Identifier | Provider |
|------------|----------|
| `openrouter.apiKey` | OpenRouter (LLM, batch transcription) |
| `deepgram.apiKey` | Deepgram (live + batch transcription, TTS) |
| `revai.apiKey` | Rev.ai (batch transcription) |
| `openai.apiKey` | OpenAI (batch transcription) |
| `openai.tts.apiKey` | OpenAI TTS |
| `elevenlabs.apiKey` | ElevenLabs TTS |
| `azure.speech.apiKey` | Azure Speech TTS |

### File Classification

**macOS-only (do NOT move to SpeakCore):**
- `SpeakApp.swift` — app entry, NSApplication
- `HUDWindow.swift` — NSWindow/NSPanel
- `HotKeyManager.swift` — CGEvent taps, NSEvent
- `LiveTextInserter.swift` — Accessibility text insertion
- `TextOutput.swift` — SmartTextOutput, AccessibilityTextOutput, PasteTextOutput
- `StatusBarView.swift` — NSStatusBar
- `Services/MenuBarManager.swift` — menu bar
- `Services/ShortcutManager.swift` — keyboard shortcuts
- `TextToSpeech/SystemTTSClient.swift` — NSSpeechSynthesizer (partial; AVSpeechSynthesizer is cross-platform)

**Candidates for SpeakCore (cross-platform):**
- `TranscriptionManager.swift` — live controllers (need iOS audio session changes)
- `TranscriptionProviderRegistry.swift` + all providers (OpenAI, Rev.ai, Deepgram)
- `OpenRouterAPIClient.swift` — networking
- `SecureAppStorage.swift` — keychain (needs access group for sync)
- `AppSettings.swift` — UserDefaults (largely portable)
- `LLMProtocols.swift`, `TranscriptionTextProcessor.swift`
- Models: `TranscriptionResult`, `HistoryItem` (partial), `PersonalLexiconModels`
- `PostProcessingManager.swift`, `PersonalLexiconService.swift`
- TTS clients (Deepgram, OpenAI, ElevenLabs, Azure) — networking only

**Needs conditional compilation (`#if os(...)`):**
- `PermissionsManager.swift` — different permission APIs per platform
- `AudioInputDeviceManager.swift` — CoreAudio vs AVAudioSession
- `AudioFileManager.swift` — AVAudioRecorder (similar but session differs)
