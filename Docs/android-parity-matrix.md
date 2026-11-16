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
| Target / compile SDK | 36 / 37 | Compile SDK 37 is required by current AndroidX; target SDK stays 36 until Android 17 behaviour changes are reviewed. |
| Devices | Phones and tablets with a microphone (`android.hardware.microphone` required) | Wear OS, TV and Auto are out of scope. |
| Build | Gradle 9.9.1 wrapper, AGP 9.5 (built-in Kotlin), Kotlin 2.4, compile SDK 37, JDK 17 | CI: [`.github/workflows/android.yml`](../.github/workflows/android.yml) on hosted Ubuntu. Dependencies come from `JSTI_MAVEN_MIRROR` when set, otherwise from Google Maven and Maven Central on GitHub-hosted runners only; other machines need a feed (see [android/README.md](../android/README.md#android-dependency-sources)). |

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
| Auto-paste / insert at cursor | **Android equivalent, done** | The dictation keyboard (IME) commits final transcripts into the focused field, with partials shown as composing text. It is disabled in password fields and never uses the app's Cloud (BYOK) providers; the phone's speech service, which may send audio to its provider, is disclosed before it is used automatically. Accessibility-service insertion is rejected because Play policy and the privacy cost are too high. See [entry and output surfaces](android-input-surfaces.md). |
| Global hotkey | **Android equivalent, done** | A Quick Settings tile and a launcher shortcut open the app and start dictation through a non-exported entry. Background hotkeys are not possible on Android. |
| Menu bar / HUD | **Android equivalent, done** | While a session records, uploads or saves its audio, a microphone foreground service shows a silent ongoing notification (Recording, Paused or Finishing) with a Stop action that finishes the session like the Stop button (#1592). |
| Microphone permission onboarding | **Launch, done** | Runtime request on first use, rationale after a denial, and a Settings link after a permanent denial. |
| Background recording | **Launch, done** | Every dictation runs under a `microphone` foreground service started while the app is visible, so it carries on with another app in front or the screen off, and Back leaves it running. If Android refuses the service, leaving the app stops the session as before ("Dictation stopped because the app left the screen") and keeps its audio and words. Whether a phone's speech service keeps listening in the background needs device evidence (`android-foreground-long-dictation`). |
| Interruptions and audio focus | **Launch, done** | The platform recogniser owns audio focus in on-device and speech-service modes. Cloud capture (`AudioRecord`, voice-recognition source) holds transient audio focus: a transient loss pauses the recording and focus coming back resumes it; a permanent loss stops it. In every mode a call (Android 12+), or a headset or Bluetooth microphone connecting or disconnecting, ends the session with its own message. Nothing is lost: Cloud audio is saved with the failed History entry, ready to transcribe, and recogniser text is kept as unfinished. Cloud capture stops automatically after 10 minutes. Device evidence: `android-interruptions-focus-route`. |
| Process death | **Launch, audio recovered** | An in-flight session is never restored as complete. A Cloud recording left by a closed screen or a dead process is recovered at the next History load as a failed entry with its audio, ready to transcribe. |
| BYOK secure storage | **Launch, done** | AES-256-GCM with a non-exportable Android Keystore key; ciphertext bound to the secret name (Mac identifiers such as `openai.apiKey`), excluded from backup and device transfer. Settings saves and removes keys and never shows a saved key again. |
| Cloud transcription providers | **Launch, done (batch)** | "Cloud" mode records 16 kHz mono WAV in the app, uploads it with the user's key and deletes it afterwards. Models: GPT Transcribe (OpenAI, `languages[]` hint) and Whisper Large v3 Turbo (Groq). The model list, IDs, names, wire fields and credential IDs come from `assets/cloud_catalog.json`, generated from `Sources/SpeakCore` by `CloudCatalogAndroidExport` (which also owns the rule for which models Android offers), and the Android build generates `CloudCatalog`'s constants from it (`generateCloudCatalog`), checked by `CloudCatalogParityTest`. Cloud is never chosen automatically. Streaming providers (Deepgram, AssemblyAI, ElevenLabs) and further batch providers are planned. No paid calls in CI. |
| Post-processing / cleanup | **Launch, done** | Optional cleanup with the Mac's cleanup model picker: native provider models (Anthropic, OpenAI, Google Gemini, Groq, Mistral) first, then one OpenRouter entry with a searchable list, each sorted by provider then model. The default stays the Mac's OpenRouter model (`openai/gpt-6-luna`), and the prompt is the shared `TranscriptCleanupPolicy`. A saved model that has been removed moves to its successor on the same route (`cleanupModelSuccessors`). The cleanup models, successors, native endpoints, default and prompt are exported to `assets/cloud_catalog.json` and generated into the Android build, checked by `CloudCatalogParityTest`. The transcript is sent as JSON data. A failure keeps the original transcript and says so; "Show original" undoes a cleanup. Settings → Cleanup prompt replaces the built-in prompt (saved under the desktop `postProcessingSystemPrompt` key) and keeps the shared closing instruction (`customPromptClosing`); a blank prompt uses the built-in one. |
| History and recovery | **Launch, done** | App-private atomic JSON file (never backed up). Retention can be Off, 7 days, 30 days (default) or Always, with at most 500 entries. Completed and failed sessions are recorded; failures keep their reason and unfinished words, labelled as unfinished. Copy, share, delete and clear all are available; models show friendly names. Cancelled sessions are not recorded. |
| Personal corrections and vocabulary | **Launch, done** | Settings → Personal corrections stores rules ("write as" plus comma-separated "heard as" aliases). Every final transcript (app, keyboard, shared audio and History retry) has the aliases replaced as whole words, ignoring case, before cleanup and History. The spellings form a vocabulary glossary sent as `prompt` to cloud models that accept one (`supportsPrompt` in the catalogue), bounded by SpeakCore's `TranscriptionKeywordPolicy` limits. |
| Learned corrections | **Android equivalent, done** | The dictation keyboard remembers the text either side of what it typed and, after SpeakCore's observation time (10 s plus 1 s per sentence, at most 30 s), reads that field again if it is still in it. Word changes found by the Kotlin copy of `WordDiffer` are counted as suggestions under the shared `autoCorrectionsEnabled`, `autoCorrectionsPromotionThreshold` (2 to 10, default 2) and `autoCorrectionCandidates` keys; at the threshold one joins Personal corrections. Settings → Learned corrections adds or dismisses suggestions. Password, no-suggestion and no-personalised-learning fields are never read, and edits made with another keyboard cannot be seen (#1651). |
| Language selection | **Launch, done** | Settings → Dictation language offers SpeakCore's `TranscriptionLanguageCatalog` (exported in `cloud_catalog.json`) and is saved under the shared `preferredLocale` key. Automatic uses the phone's language on every route, because Android's recognisers need a concrete locale; a chosen language is used by all modes and the keyboard, and on-device support is rechecked for it. |
| Profiles | **Launch, done** | Settings → Dictation profiles stores profiles in SpeakCore's `DictationProfile` JSON shape under the shared `dictationProfiles` key (field names exported as `profiles` in `cloud_catalog.json`), keeping fields Android cannot edit. A profile sets the cloud transcription model, language, cleanup on/off, cleanup model and cleanup prompt; it never changes the recognition mode, and the cloud model applies only in Cloud mode. Choose the active profile on the dictation screen or with the keyboard's Profile key (the keyboard applies the language). Android cannot see the frontmost app, so app matchers are kept but not used. |
| Audio / file transcription | **Android equivalent, done** | Share audio (MP3, M4A, WAV, OGG/Opus, WebM, FLAC; at most 25 MB) into the app; it is uploaded to the chosen cloud model after confirmation and recorded in History. |
| Usage insights | **Launch, done (basic)** | History shows dictations and words in the last 7 days, counted locally from completed History entries. |
| Voice output (TTS) | **Launch, partial** | Read aloud on a finished transcript uses the phone's `TextToSpeech` engine. Cloud voices are not planned for launch. |
| Downloaded local models (Parakeet, WhisperKit, etc.) | **Planned** | Assessed in [android-on-device-models.md](android-on-device-models.md) (#1593): whisper.cpp with the shared `local/whisperkit/*` pins for transcription (#1658), Gemini Nano through the ML Kit Prompt API on supported phones (#1659) and llama.cpp GGUF models (#1660) for cleanup. ML Kit GenAI speech recognition and sherpa-onnx are deferred. The platform recogniser covers launch. |
| Keyboard extension (iOS) | **Android equivalent, done** | Dictation keyboard (IME). |
| Share extension | **Android equivalent, done (audio)** | Share target for audio. Text in is not needed, as cleanup runs on dictated text. |
| Widgets / Live Activity | **Deferred** | The Quick Settings tile and shortcut cover quick start; a home-screen widget only if it adds value. |
| Watch app | **Not applicable (for now)** | Wear OS is out of scope for the first release. |
| iCloud / CloudKit sync | **Not applicable** | Apple-only; cross-device sync would need a separate design. |
| Sparkle updates, DMG, Homebrew | **Not applicable** | Distribution is through Google Play or sideloaded APKs. |
| Automation CLI (`speak`) | **Not applicable** | Desktop-only; Android intents and shortcuts cover automation. |
| Tip jar | **Done** (#1594) | Google Play Billing consumables with the Apple product IDs from SpeakCore's `TipCatalog`; the owner creates the products in Play Console. Paid access is not planned. |
| Analytics / crash reporting | **Done, opt-in** (#1594) | Both off until the user opts in. PostHog EU sends the Mac's `app_active_daily`, `analytics_opt_in` and `first_transcription_succeeded`; Sentry EU receives crash reports from release builds only. |

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
9. Quick Settings tile and shortcut on a locked and an unlocked device; sharing a WhatsApp voice note (OGG/Opus) and an M4A recording.
10. Dictation keyboard in a messaging app, a browser field and a password field (disabled), including switching keyboards mid-dictation and denying the microphone permission.
11. A chosen dictation language (for example French) in each mode and the keyboard, and Automatic following the phone language.
12. Personal corrections fixing a misheard name in each mode, and Read aloud on a finished transcript.

These checks are on the owner's QA page (`Docs/manual-checks.yml`, Android session).

