# Android parity matrix

Status of the native Android app (`android/`, epic #1328) against the Mac app. The Mac
inventory comes from the [README](../README.md), [Architecture](Architecture.md) and
`Sources/SpeakApp`. This matrix is the agreed launch scope: update it in the same pull
request that changes an Android capability.

Status key:

- **Launch**: in the first Android release scope. "Done" means implemented and covered by
  unit tests; physical-device evidence is tracked separately below.
- **Planned**: a later milestone, with the delivery issue or PR when one exists.
- **Android equivalent**: delivered through a different, Android-native surface.
- **Not applicable**: deliberately not offered on Android, with the reason.

## Stack and supported devices

| Decision | Choice | Reason |
| --- | --- | --- |
| Language and UI | Kotlin, Jetpack Compose, Material 3 | Native toolkit; no web view or Swift runtime. |
| Architecture | One `app` module: pure Kotlin state/policy, a thin platform adapter, one ViewModel | Keeps the dictation path short and testable on the JVM. Split modules only when a second surface (IME, Quick Settings) needs shared code. |
| Minimum Android | Android 10 (API 29) | Covers the large majority of active devices while avoiding legacy storage and permission paths. |
| On-device recognition | Android 12+ (API 31) where the speech service provides it; language checks and model download on Android 13+ (API 33) | These are the platform API levels for `createOnDeviceSpeechRecognizer`, `checkRecognitionSupport` and `triggerModelDownload`. |
| Target / compile SDK | 36 | Current platform behaviour. |
| Devices | Phones and tablets with a microphone (`android.hardware.microphone` required) | Wear OS, TV and Auto are out of scope. |
| Build | Gradle 8.14.3 wrapper, AGP 8.13, Kotlin 2.2, JDK 17 | CI: [`.github/workflows/android.yml`](../.github/workflows/android.yml) on hosted Ubuntu. Dependencies come from `JSTI_MAVEN_MIRROR` when set, otherwise from Google Maven and Maven Central on GitHub-hosted runners only; other machines need a feed (see [android/README.md](../android/README.md#android-dependency-sources)). |

## Feature matrix

| Mac feature | Android status | Android approach / reason |
| --- | --- | --- |
| Start/stop dictation | **Launch, done** | One large record button; Stop asks the recogniser for its final result. |
| Live partial text | **Launch, done** | `EXTRA_PARTIAL_RESULTS`; partials replace the hypothesis and are always styled as provisional. |
| Final transcript | **Launch, done** | Only a non-empty final result becomes "Transcript ready". Errors, silence and cancellations never look successful; partial words are offered as "Unfinished text". |
| On-device (private) recognition | **Launch, done** | `SpeechRecognizer.createOnDeviceSpeechRecognizer` on Android 12+. Availability, language support and missing models are detected and explained (a support check that does not answer within 3 seconds counts as unknown). On Android 13+ a model download can be requested, and support is rechecked every 5 seconds until it installs. |
| Apple Speech server recognition | **Android equivalent, done** | "Speech service" mode uses the default `RecognitionService`, labelled as possibly sending audio to its provider. |
| No silent cloud fallback | **Launch, done** | A running session keeps its mode and privacy label even if availability changes. An explicit choice is kept for the app's lifetime (persisted in milestone 2); without one, the app picks on-device, then the speech service, and labels which. An unusable choice disables Start with the reason. |
| Copy | **Launch, done** | Clipboard; Android 13+ shows the system confirmation. |
| Share | **Launch, done** | Standard share sheet (`ACTION_SEND`). |
| Auto-paste / insert at cursor | **Android equivalent, planned** | Android does not allow unrestricted cross-app insertion. The equivalent is an input method (IME) that commits text into the focused field (milestone 4). Accessibility-service insertion is rejected: Play policy and privacy cost are too high. |
| Global hotkey | **Android equivalent, planned** | Quick Settings tile and app shortcut to start dictation (milestone 4). Background hotkeys are not possible on Android. |
| Menu bar / HUD | **Android equivalent, planned** | Foreground-service notification with Stop while a session runs, if longer sessions are added; otherwise the in-app screen. |
| Microphone permission onboarding | **Launch, done** | Runtime request on first use, rationale after a denial, and a Settings link after a permanent denial. |
| Background recording | **Launch, done (honest stop)** | Leaving the app cancels the session and reports "Dictation stopped because the app left the screen". A foreground service for longer sessions is assessed with the IME/tile milestone. |
| Interruptions and audio focus | **Launch, partial** | The platform recogniser owns capture and audio focus in on-device and speech-service modes; its audio/busy/client errors are surfaced as failures. Cloud capture uses `AudioRecord` (voice-recognition source) and fails visibly if the microphone cannot open; it stops automatically after 10 minutes. Calls and route changes need physical-device evidence. |
| Process death | **Launch, honest loss** | An in-flight session is discarded, never restored as complete. Leaving the app while dictating records a failed history entry with the unfinished words. |
| BYOK secure storage | **Launch, done** | AES-256-GCM with a non-exportable Android Keystore key; ciphertext bound to the secret name (Mac identifiers such as `openai.apiKey`), excluded from backup and device transfer. Settings saves and removes keys and never shows a saved key again. |
| Cloud transcription providers | **Launch, done (batch)** | "Cloud" mode records 16 kHz mono WAV in the app, uploads it with the user's key and deletes it afterwards. Models: GPT Transcribe (OpenAI, `languages[]` hint) and Whisper Large v3 Turbo (Groq). IDs, names, credential IDs and retirement status are checked against `Sources/SpeakCore` by `CloudParityTest`. Cloud is never chosen automatically. Streaming providers (Deepgram, AssemblyAI, ElevenLabs) and further batch providers are planned. No paid calls in CI. |
| Post-processing / cleanup | **Launch, done** | Optional OpenRouter cleanup with the Mac default model (`openai/gpt-5-mini`) and the shared `TranscriptCleanupPolicy` prompt, which `CloudParityTest` keeps identical. The transcript is sent as JSON data. A failure keeps the original transcript and says so; "Show original" undoes a cleanup. Custom prompts arrive with profiles. |
| History and recovery | **Launch, done** | App-private atomic JSON file (never backed up). Retention can be Off, 7 days, 30 days (default) or Always, with at most 500 entries. Completed and failed sessions are recorded; failures keep their reason and unfinished words, labelled as unfinished. Copy, share, delete and clear all are available; models show friendly names. Cancelled sessions are not recorded. |
| Personal corrections and vocabulary | **Planned (milestone 3)** | Applied after recognition; keyterms passed to providers that support them. |
| Language selection | **Planned (milestone 3)** | Launch uses the device language, resolved against the on-device model list. |
| Profiles | **Planned (later)** | After providers and history exist. |
| Audio / file transcription | **Planned (later)** | Share target for audio files into a batch provider. |
| Usage insights | **Planned (later)** | Local-only statistics derived from history. |
| Voice output (TTS) | **Planned (later)** | Android `TextToSpeech` first, cloud voices later. |
| Downloaded local models (Parakeet, WhisperKit, etc.) | **Planned (assess)** | Assess ML Kit GenAI speech recognition and on-device Whisper runtimes against size and battery; the platform recogniser covers launch. |
| Keyboard extension (iOS) | **Android equivalent, planned** | IME, milestone 4. |
| Share extension | **Android equivalent, planned** | Share target for text and audio, milestone 4. |
| Widgets / Live Activity | **Planned (assess)** | Quick Settings tile first; a home-screen widget only if it adds value. |
| Watch app | **Not applicable (for now)** | Wear OS is out of scope for the first release. |
| iCloud / CloudKit sync | **Not applicable** | Apple-only; cross-device sync would need a separate design. |
| Sparkle updates, DMG, Homebrew | **Not applicable** | Distribution is through Google Play or sideloaded APKs. |
| Automation CLI (`speak`) | **Not applicable** | Desktop-only; Android intents and shortcuts cover automation. |
| Tip jar / paid access | **Planned (assess)** | Requires Google Play Billing and owner account setup. |
| Analytics / crash reporting | **Planned (assess)** | Only with the same consent model as the Mac app. |

## Evidence still required on physical devices

Unit tests and CI cannot prove these; they gate closing the epic:

1. On-device recognition on a Pixel (Android 13+) and a non-Google OEM device, including an
   offline (flight mode) session.
2. Missing language model: Download, then a successful session after the model installs.
3. A device with no recognition service, or with it disabled, shows the reason and no Start.
4. Microphone permission denial, permanent denial and Settings recovery.
5. Interruptions: incoming call, Bluetooth headset connect/disconnect, and leaving the app.
6. Speech-service and Cloud modes with no network either return a genuine transcript (speech service with an installed offline model) or fail visibly; they never show a false success.
7. Battery and latency notes for a five-minute dictation series.
8. Cloud mode with a real OpenAI and Groq key, an invalid key ("rejected the API key"), and cleanup with an OpenRouter key; owner-only, as these calls are paid.
