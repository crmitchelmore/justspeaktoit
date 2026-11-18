# Feature map

What every user-facing feature does on each platform, how it should behave,
what it must not do, and when parts of it go away. Agents: **check this map
before building, changing or removing a feature**, and update it in the same
pull request whenever a platform gains, loses or changes a feature.

Every claim here was checked against the code in November 2026. When code and
this map disagree, the code wins: fix the map in your PR.

`scripts/check-feature-map.py` checks that IDs are unique, the summary table
matches each entry, every gap names an issue, every exclusion gives a reason and
every cited path and link exists. `make test-tooling` runs it, so CI Lint catches
a code change that moves a cited file; CI skips Lint for docs-only changes, so
run `python3 scripts/check-feature-map.py` yourself after editing this map.

Platform acceptance evidence stays in the
[Android parity matrix](android-parity-matrix.md),
[Windows development](windows-development.md#feature-parity-matrix),
[Linux development](linux-development.md) and
[desktop settings coverage](desktop-settings-parity.md).

## How to read an entry

- **Platforms:** `Yes` implemented; `Partial` implemented with a gap tracked by
  an issue; `Limited` implemented as far as the OS allows; `No` missing (see the
  issue); `N/A` deliberately excluded.
- **Excluded:** each `N/A` platform and why, as `;`-separated clauses of the form
  `<platforms> (OS: …)` when the platform cannot support it or
  `<platforms> (owner decision: …)` when the owner chose not to build it. Do not
  build an excluded feature without a new owner decision.
- **Gaps:** the `No`/`Partial` platforms, then the one cross-platform issue from
  the summary row (`iOS, Android #1650 (…)`).
- **How:** the behaviour a new platform must match, then the shared type to reuse.
- **Refs:** the reference implementation: shared code first, then platform files.
- **Sunset:** what is scheduled to be removed or migrated, and the trigger.
- **Nuances:** gotchas that have bitten before.

## Rules for every feature

- **Shared first.** Put logic, catalogues and policies in `SpeakCore` (Apple and
  portable) or `SpeakDesktop`/`SpeakDesktopHost` (Windows and Linux); platforms
  add only UI and native adapters. Android consumes exported JSON
  (`android/app/src/main/assets/cloud_catalog.json`, `settings_search.json`)
  generated from `SpeakCore`; never hand-edit a copied list. See
  [AGENTS.md](../AGENTS.md) (Cross-Platform Features, Shared Evolving Catalogues).
- **One issue per gap.** If a platform can't get a feature in the same change,
  file or extend one cross-platform issue and mark it here.
- **Settings search.** Every new setting, card or page goes in
  `SettingsSearchCatalog` with its on-screen title ([settings search](settings-search.md)).
- **Accessibility.** Every control needs a name, role, state and stable
  automation ID; recording changes are announced ([accessibility](accessibility.md)).
- **Privacy.** Logs, analytics, crash reports and issue reports never contain
  transcript text, audio, API keys or prompts. Secrets live only in platform
  secure storage.
- **Human checks run on Alpha after merge.** Add device or owner checks to
  `Docs/manual-checks.yml`; they appear in the next Alpha's notes and on
  `justspeaktoit.com/qa` ([manual QA](manual-qa.md)). They never block a merge.
- **No UI tests on the owner's Mac.** `scripts/pre-pr` runs unit tests only;
  CI runs UI and journey tests.
- **Retiring models.** Provider shutdowns go in `ModelRetirements`
  (`Sources/SpeakCore/ModelRetirements.swift`): the entry is labelled until its
  UTC shutdown day, then hidden; saved selections move only to a verified
  equivalent, otherwise requests fail with `ModelRetiredError` until the user
  picks a replacement. Removed cleanup models migrate through
  `CleanupModelRemovals` (`Sources/SpeakCore/PostProcessing/CleanupModelRemovals.swift`).
- **Deprecated public APIs.** `@available(*, deprecated)` symbols in exported
  libraries (SpeakCore and friends) stay until a declared breaking change
  (`!` in the PR title); `scripts/ci-api-compatibility.sh` enforces this.

### Build flags that gate features

| Flag (`tuist generate`) | Gates | Default | Remove when |
| --- | --- | --- | --- |
| `TUIST_IOS_KEYBOARD` | iOS keyboard extension (F50) | On in every release train | Already permanent; the flag only keeps local builds simple. |
| `TUIST_IOS_KEYBOARD_DIRECT_CAPTURE` | Keyboard records the mic itself (#661) | Off in every release | Apple gives keyboards no microphone, so the direct-capture shape is an experiment; delete it if #661 closes without a route. |
| `TUIST_WATCH_APP` | watchOS companion (W01) | Alpha only | Owner approves shipping the watch app on Stable ([watch provisioning](watch-provisioning.md)). |
| `TUIST_IOS_SHARE_EXTENSION` | iOS Share extension (F39) | Alpha only | Owner approves it for Stable. |
| `TUIST_IOS_SHARED_CLOUD_CONTAINER` | Nothing in current source: `release-ios.yml` still sets it so frozen older sources join the shared CloudKit container (F17) | `1` in release | Drop it with the rest of the #1119 migration (F17). |
| `TUIST_PAID_ACCESS` | Paid access (F38) | Off ("compiled dark") | Owner launches paid access ([paid access](paid-access.md)). |

The flags live in `Project.swift`; release selection is in
`.github/workflows/release-ios.yml`.

## Summary

| # | Feature | macOS | iOS | Windows | Linux | Android | Issue | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| F01 | Global record hotkey (hold, toggle, double-tap) | Yes | N/A | Yes | Limited | N/A | | Linux depends on the Wayland portal. |
| F02 | Custom action shortcuts | Yes | N/A | Yes | Yes | N/A | | |
| F03 | Live streaming cloud transcription | Yes | Yes | Yes | Yes | Partial | #1590 | Android streams Deepgram, AssemblyAI, OpenAI Realtime and ElevenLabs only. |
| F04 | Batch cloud provider catalogue | Yes | Yes | Yes | Yes | Yes | | |
| F05 | Downloaded local transcription models | Yes | Partial | Yes | Yes | Partial | #1650 | iOS: WhisperKit Core ML batch transcription only; no live, sherpa-onnx or Phonon models. Android: whisper.cpp batch; the keyboard offers only Tiny and Base, with a shorter recording limit. |
| F06 | Platform on-device recogniser | Yes | Yes | N/A | N/A | Yes | | |
| F07 | Remote cleanup (OpenRouter and native LLMs) | Yes | Yes | Yes | Yes | Yes | | |
| F08 | Local LLM cleanup | Yes | Partial | Yes | Yes | Partial | #1650 | iOS: downloaded llama.cpp models compiled into the app, CPU only; device measurements pending. Android: Gemini Nano on phones whose AICore offers it, and downloaded llama.cpp models in the app and profiles; the keyboard runs only short cleanups that fit its 10-second bound. |
| F09 | Custom cleanup prompt | Yes | Yes | Yes | Yes | Yes | | |
| F10 | Browse OpenRouter models picker | Yes | Yes | Yes | Yes | Yes | | Batch and cleanup pickers only; streaming pickers have none because OpenRouter can't stream. Windows and Linux also keep OpenRouter routes in the picker. |
| F11 | Dictation profiles | Yes | Limited | Yes | Yes | Limited | | iOS and Android cannot see the frontmost app. |
| F12 | Vocabulary, corrections, pronunciation | Yes | Yes | Yes | Yes | Yes | — | Corrections also restore the stored spelling's case. |
| F13 | Transcription language selection | Yes | Yes | Yes | Yes | Yes | | |
| F14 | History list and search | Yes | Yes | Yes | Yes | Yes | | |
| F15 | History filters (model, errors, dates) | Yes | Yes | Yes | Yes | Yes | | Android filters by Cloud model or recognition mode. |
| F16 | History retry and audio playback | Yes | Yes | Yes | Yes | Yes | | Android keeps recordings only when "Keep recordings in History" is on. |
| F17 | History sync | Yes | Yes | Yes | Yes | Yes | | Desktops and Android use CloudKit Web Services. |
| F18 | Settings search | Yes | Yes | Yes | Yes | Yes | | |
| F19 | Command palette | Yes | N/A | Yes | Yes | N/A | | Windows and Linux also list recent History. |
| F20 | Compare models | Yes | N/A | Yes | Yes | N/A | #1622 | Desktop-only by owner decision. |
| F21 | Voice output / read aloud | Yes | Yes | Yes | Yes | Yes | | OpenAI `/v1/audio/speech` voices N/A on Android (retire 2027-01-06). |
| F22 | Voice edit of selected text | Yes | Yes | Yes | Limited | Yes | | Linux: external editable AT-SPI fields with session selection access only. Android: from the dictation keyboard. |
| F23 | Hands-free and silence auto-stop | Yes | Yes | Yes | Yes | Yes | | Android: Cloud mode only. |
| F24 | Insert text into other apps | Yes | Limited | Yes | Limited | Yes | | |
| F25 | Recording HUD / live text overlay | Yes | Yes | Yes | Yes | Partial | #1592 | Android shows an ongoing foreground-service notification with Stop, but no live text. |
| F26 | Menu bar / tray presence | Yes | N/A | Yes | Yes | N/A | | |
| F27 | Resources-in-use status | Yes | Yes | Yes | Yes | Yes | | |
| F28 | Report an issue with diagnostics | Yes | Yes | Yes | Yes | Yes | | |
| F29 | Troubleshooting page | Yes | Yes | Yes | Yes | Yes | | Phone rules shared in SpeakCore; Android reads them from an exported asset. |
| F30 | Onboarding and permissions guide | Yes | Yes | Yes | Yes | Yes | | |
| F31 | API keys page | Yes | Yes | Yes | Yes | Yes | | |
| F32 | Provider credit balances | Yes | Yes | Yes | Yes | Yes | | Android reads Deepgram, ElevenLabs, OpenRouter and Rev AI. |
| F33 | Configuration export/import and backup | Yes | Yes | Yes | Yes | Yes | | Android: settings, profiles, corrections, History, WAV recordings, keys opt-in. Windows and Linux: every category, keys opt-in; models are named, never copied. |
| F34 | Raw settings editor and config tools | Yes | Partial | Yes | Yes | Partial | #1608 | iOS and Android have the raw JSON editor but no automation server, so no config tools. Windows and Linux have the raw JSON editor window, `speak config` and MCP `get_configuration`/`set_configuration`. |
| F35 | Automation (CLI, MCP, App Intents) | Yes | Yes | Yes | Yes | Limited | | |
| F36 | Usage insights dashboard | Yes | Yes | Yes | Yes | Limited | | iOS, Android: no spend (their History records no cost). Android: no top words, vocabulary or word of the month (no lemmatiser); unspaced Chinese and Japanese text counts as one word per run. |
| F37 | Opt-in analytics and crash reporting | Yes | Yes | Yes | Yes | Yes | | |
| F38 | Tip jar / paid access | Yes | Yes | Yes | Yes | Yes | | Paid access is compiled dark on every platform (#648). Windows, Linux: About's Support development opens GitHub Sponsors or Ko-fi. Android: Google Play tips. |
| F39 | Audio file import | Yes | Yes | Yes | Yes | Yes | | |
| F40 | Launch at login | Yes | N/A | Yes | Yes | N/A | | |
| F41 | Updates | Yes | N/A | Yes | Yes | N/A | | |
| F42 | Microphone selection | Yes | Yes | Yes | Yes | Yes | | Android: Cloud recordings only. |
| F43 | Recording start/stop sounds | Yes | Yes | Yes | Yes | Yes | | |
| F44 | Per-app output target (profiles) / Focus overrides | Yes | Yes | Yes | Limited | N/A | | |
| F45 | Recording audio housekeeping | Yes | Yes | Yes | Yes | Partial | #1629 | |
| F46 | Send transcripts from phone to desktop | Yes | Yes | Yes | Yes | Yes | | iOS: pair in Settings › Sync & Transfer › Send to Mac, then send from History; no auto-send. Android: pair in Settings › Send to Mac, then send from History; Stable Macs only. macOS: direct build only; the Mac App Store build has no receiver. Windows and Linux: receive only, from Settings › iCloud Sync › Send from phone; Linux (native and Flatpak) needs the host's avahi-daemon. |
| F47 | Accessible names, IDs and recording announcements | Yes | Yes | Yes | Yes | Yes | | |
| F48 | Learned auto-corrections | Yes | Yes | Yes | Yes | Limited | | iOS learns from edits to text its keyboard inserted. Android learns only from edits made while its keyboard is in the field. |
| F49 | Appearance settings | Yes | Yes | Yes | Yes | Yes | | |
| F50 | Keyboard / IME surface | N/A | Yes | N/A | N/A | Yes | | Android can stream live Cloud models as an explicit opt-in. |
| F51 | Consent before sharing with cloud AI providers | Yes | Yes | Yes | Yes | Yes | | Asked once per provider and data kind, per device; withdraw in Privacy settings. |

## Features

### F01 Global record hotkey (hold, toggle, double-tap)
- **Platforms:** macOS Yes · iOS N/A · Windows Yes · Linux Limited · Android N/A
- **Excluded:** iOS (OS: no background key events; use the Action Button, Controls and App Intents); Android (OS: no global keys; use the Quick Settings tile and launcher shortcut).
- **Gaps:** none
- **How:** One gesture machine decides hold, toggle and double-tap from key down/up timing; platforms only deliver key events. Reuse `HotKeyGestureMachine` and `HotKeySessionPolicy`.
- **Refs:** `Sources/SpeakCore/Recording/HotKeyGestureMachine.swift`, `Sources/SpeakDesktopHost/Settings/DesktopHostShortcutGestures.swift`, `Sources/SpeakApp/Hotkeys/HotKeyManager.swift`, `Sources/SpeakWindows/WindowsHotKey.swift`, `Sources/SpeakLinux/LinuxGlobalActionShortcuts.swift`
- **Sunset:** none
- **Nuances:** Linux global shortcuts need the GlobalShortcuts portal (GNOME 48+, KDE Plasma 6); real-desktop behaviour is still unverified ([Linux development](linux-development.md)). The Mac warms the input path on first tap (`Sources/SpeakApp/Hotkeys/HotKeyInputWarmUp.swift`).

### F02 Custom action shortcuts
- **Platforms:** macOS Yes · iOS N/A · Windows Yes · Linux Yes · Android N/A
- **Excluded:** iOS, Android (OS: no background key handling).
- **Gaps:** none
- **How:** Users bind extra keys to app actions from the shared shortcut catalogue; conflicts are detected before saving.
- **Refs:** `Sources/SpeakCore/DesktopShortcutCatalog.swift`, `Sources/SpeakDesktopHost/Settings/DesktopHostShortcutBindings.swift`, `Sources/SpeakApp/Views/Settings/ShortcutsSettingsView.swift`, `Sources/SpeakWindows/WindowsActionShortcuts.swift`, `Sources/SpeakLinux/LinuxActionShortcuts.swift`
- **Sunset:** none
- **Nuances:** Linux chords are translated by `Sources/SpeakCore/Desktop/DesktopShortcutLinuxChord.swift`; don't hand-format portal triggers.

### F03 Live streaming cloud transcription
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** Android #1590 (streams Deepgram, AssemblyAI, OpenAI Realtime and ElevenLabs Scribe realtime (#1667); other live routes are not yet offered).
- **How:** Shared provider clients in `SpeakCore/Live` own protocol, readiness, framing and finish sequencing; platform adapters only feed PCM and render text. Interim text replaces the current turn; only finals commit. Change the shared client, not an adapter.
- **Refs:** `Sources/SpeakCore/Live/Providers`, `Sources/SpeakCore/LiveModelCapabilities.swift`, `Sources/SpeakApp/Live/SharedClientLiveController.swift`, `Sources/SpeakDesktop`, `android/app/src/main/java/com/justspeaktoit/android/cloud/live`
- **Sunset:** OpenAI GPT-4o streaming models shut down 2027-02-26 and Mistral Voxtral Realtime 2027-04-30 (`ModelRetirements`). Saved AssemblyAI Universal-3.5 Pro streaming IDs migrate to Universal-3.6 Pro (`AssemblyAIModels.legacyUniversal3StreamingIDs` in `Sources/SpeakCore/Transcription/Providers/AssemblyAIModels.swift`).
- **Nuances:** OpenRouter cannot stream transcription, so it never appears in streaming pickers ([OpenRouter audio](openrouter-audio.md)). Provider-specific protocol rules (AssemblyAI, OpenAI Realtime, xAI) are in AGENTS.md. Install audio taps only with `installTapSafely`. Android's Kotlin clients (`cloud/live`) mirror the shared finish sequencing: budgets start once queued audio has left the device, a close after the end signal completes only on a clean 1000 close, OpenAI waits for the final committed item's completion (failing with the heard text at the 8 s deadline), and ElevenLabs sends one manual commit and reads finals for the 1.5 s post-commit window, counting a segment's timestamped twin once.

### F04 Batch cloud provider catalogue
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** One catalogue (`ModelCatalog`) lists batch providers and models; platforms show a filtered projection of routes their host can run. Saved IDs are `provider/model`.
- **Refs:** `Sources/SpeakCore/ModelCatalog.swift`, `Sources/SpeakCore/Batch/BatchTranscriptionRouting.swift`, `Sources/SpeakCore/CloudCatalogAndroidExport.swift`, `Sources/SpeakiOS/Settings/AppSettings+Models.swift`, `android/app/src/main/java/com/justspeaktoit/android/cloud/CloudCatalog.kt`
- **Sunset:** OpenAI `whisper-1` and GPT-4o transcribe models 2027-02-26, `mistral/voxtral-mini-latest` 2027-04-30 and OpenRouter `openai/gpt-audio` 2027-01-20 (`ModelRetirements`). Legacy AssemblyAI and ElevenLabs batch IDs migrate (`legacyUniversal3BatchIDs`, `legacyElevenLabsBatchIDs`).
- **Nuances:** iOS calls the shared SpeakCore clients for Deepgram, AssemblyAI, ElevenLabs, Groq, Mistral, Modulate, Rev AI, Soniox and Speechmatics (`BatchTranscriptionRouting.iosSharedClientProviderIDs`, `Sources/SpeakiOS/Services/IOSBatchTranscriptionClient+SharedProviders.swift`), each with the provider's own key. Android uploads to OpenAI and Groq through the OpenAI-compatible form, and to AssemblyAI, Cartesia, Deepgram, ElevenLabs, Gemini (Google), Gladia, Meta Muse Voice, Mistral, Modulate, OpenRouter audio models, Reson8, Rev AI, Smallest, Soniox, Speechmatics, xAI speech-to-text, Azure Speech and MAI, Alibaba Model Studio and StepFun through Kotlin clients that match the shared clients' wire formats (`android/app/src/main/java/com/justspeaktoit/android/cloud/BatchWire.kt`, `BatchTranscriber.kt`), each with its own key from API keys. Region-bound keys are stored in the Apple encodings so configuration transfer moves them unchanged (`android/app/src/main/java/com/justspeaktoit/android/cloud/RegionalCredentials.kt`): Azure as `key:region`, with an optional HTTPS Speech resource endpoint kept on the phone as on Apple devices (Android has no Azure local proxy, so `local-proxy/` tokens are refused); Alibaba as JSON carrying its region and workspace, which picks the workspace host with no cross-region retry (Fun-ASR and Qwen3.5-Omni-Plus need Beijing or Singapore); StepFun as JSON carrying the issuing region, a plain key meaning China, and a 401 or 403 reports the region rather than trying the other one. Azure and Alibaba take only Android's WAV (`requiresPCM16WAV`), so a shared non-WAV file is refused. General audio models invent text from silence, so Android never sends Gemini, OpenRouter, Alibaba or the OpenAI-compatible route a recording of its own WAV that stays below SpeakCore's default silence threshold in every 100 ms window (`WavFormat.isQuiet`); it ends as no speech (#1788). HTTP 402 and OpenAI's 429 `insufficient_quota` report an out-of-credit account, not a rate limit (#1789). Android's catalogue is generated (`CloudCatalogAndroidExport.transcriptionProviderIDs`); `CloudCatalogParityTest` fails when it drifts from the export (`android/app/src/test/java/com/justspeaktoit/android/cloud/CloudCatalogParityTest.kt`). Android always sends a concrete language (Automatic means the phone's language), so a Reson8 model whose language list lacks it fails with "language not supported" before upload; Speechmatics and AssemblyAI therefore never auto-detect on Android either. Soniox uploads and transcriptions are deleted after every request, and an abandoned Gladia or Speechmatics job is cancelled. Gladia, Meta and xAI send the language only when the model lists it (exported as `languageHints`) and otherwise auto-detect; Smallest's Pulse Pro is English only. Meta and OpenRouter's Inkling models take only the 16 kHz mono 16-bit WAV Android records (`requiresPCM16WAV`), and OpenRouter refuses WebM. Gemini sends recordings over 13 MB through the Files API. OpenRouter audio models keep their vendor's prefix (`google/gemini-2.5-flash`), so Android resolves their route from the export, never from the ID prefix. OpenAI models sent other than directly (`whisper-1`, GPT-4o) are not offered because each has an announced retirement. Catalogue membership alone is not support: a platform lists only routes it implements. A provider with several engines behind one endpoint pins the engine per ID: Reson8's Rumble-2 and Resonant-1 batch and streaming IDs each send their own `model` and check their own language list (`Sources/SpeakCore/Batch/Reson8Model.swift`); Android exports each model's list as `languageCodes`.

### F05 Downloaded local transcription models
- **Platforms:** macOS Yes · iOS Partial · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** iOS, Android #1650 (iOS: live streaming with a downloaded model and non-WhisperKit runtimes; Android: the pinned whisper.cpp models, batch, in the app and (Tiny and Base only) the keyboard, with device measurements, hands-free, shared audio, imports and Parakeet still to come, #1658; see [Android on-device models](android-on-device-models.md)).
- **How:** Downloaded models use `local/...` IDs and stay separate from Apple Speech (`apple/local/...`). Show catalogue source, size, downloaded/prepared state and runtime install state; hide runtime install controls once installed.
- **Refs:** `Sources/SpeakCore/ModelCatalog+LocalModels.swift`, `Sources/SpeakCore/LocalModels/LocalModelIdentity.swift`, `Sources/SpeakApp/LocalModels/LocalModelManager.swift`, `Sources/SpeakDesktopHost/LocalModels/DesktopHostLocalModelHost.swift`, `Sources/SpeakiOS/LocalModels/IOSLocalModelManager.swift`, `SpeakiOSApp/LocalModels/WhisperKitLocalTranscriptionEngine.swift`, `Sources/SpeakCore/WhisperCppAndroidExport.swift`, `android/app/src/main/java/com/justspeaktoit/android/local/`, `android/app/src/main/cpp/`
- **Sunset:** none
- **Nuances:** Resolve imported model IDs to friendly names everywhere (History, headers). A model in use can't be removed mid-recording (`Sources/SpeakDesktopHost/LocalModels/DesktopHostLocalModelRemoval.swift`). iOS projects the catalogue through `LocalModelHostSupport.iOS` (`ModelCatalog.iOSLocalTranscription`: WhisperKit Core ML only, plus Hugging Face WhisperKit imports) and offers them under Local › Downloaded Model for batch transcription of completed recordings; Apple Speech (F06) stays the live on-device route. Only the app target links WhisperKit and registers the engine (`IOSLocalTranscriptionEngines`), so the keyboard and other extensions report a downloaded model unavailable instead of uploading. A selected model that is missing or not downloaded fails the recording; it never falls back to a cloud provider. Larger models are flagged as slow on devices WhisperKit does not recommend them for rather than hidden. Android builds whisper.cpp v1.9.5 from its SHA-256-pinned source archive into one JNI library whose ggml llama.cpp (#1660) will share, and offers the shared `WhisperCppModels` pins from `assets/whisper_models.json` (generated by `WhisperCppAndroidExport`, checked by `WhisperCppAndroidExportTests`): Tiny, Base and Small everywhere, Large v3 Turbo only on phones with at least 5 GiB of memory. Downloads wait for Wi-Fi unless mobile data is allowed, resume, and are checked against the pinned size and SHA-256 before use. Downloaded is a separate mode, batch only (16 kHz mono WAV, transcribed after Stop); a missing or corrupt model fails visibly and History keeps the recording for a retry, never falling back to Cloud or the platform recogniser. The keyboard honours a Downloaded choice only when `KeyboardLocalModels.whisperLimitSeconds` estimates the model finishes inside the keyboard's 10-second finish bound (8 seconds of it, from deliberately slow load and per-30-second-window rates, not measurements): Tiny records for up to 120 seconds and Base for up to 60, while Small and Large v3 Turbo stay app-only. A model that is too slow, not downloaded or without its runtime leaves the platform recogniser in use, and the keyboard's status says so; a run that still passes the bound fails visibly with nothing typed and never falls back. A voice edit's instruction never uses a downloaded model.

### F06 Platform on-device recogniser
- **Platforms:** macOS Yes · iOS Yes · Windows N/A · Linux N/A · Android Yes
- **Excluded:** Windows, Linux (OS: no system speech recogniser the app can use; desktops use downloaded local models, F05).
- **Gaps:** none
- **How:** Apple Speech on Apple platforms and Android `SpeechRecognizer`; check availability before offering it.
- **Refs:** `Sources/SpeakCore/AppleSpeech/AppleSpeechAnalyzerTranscriber.swift`, `Sources/SpeakCore/LocalModels/AppleLocalModels.swift`, `android/app/src/main/java/com/justspeaktoit/android/dictation/DictationEngineSelector.kt`, `android/app/src/main/java/com/justspeaktoit/android/dictation/RecognizerAvailability.kt`
- **Sunset:** The saved ID `apple/local/SFSpeechRecognizer` is a legacy alias (`AppleLocalModels.legacySpeechModelID`); keep migrating it.
- **Nuances:** `AppleSpeechDetector` is deprecated because detector-only analyzers trap on macOS 27; use `HandsFreeVoiceActivitySession` (`Sources/SpeakCore/AppleSpeech/AppleSpeechDetector.swift`).

### F07 Remote cleanup (OpenRouter and native LLMs)
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Cleanup models come from `ModelCatalog.postProcessing`: native provider routes (`native/<provider>/<model>`) are listed before OpenRouter slugs (unprefixed IDs). Empty or silent recordings stay empty; never emit placeholder text.
- **Refs:** `Sources/SpeakCore/ModelCatalog.swift`, `Sources/SpeakCore/PostProcessing/NativeTextModels.swift`, `Sources/SpeakDesktop/Transcription/DesktopPostProcessing.swift`, `android/app/src/main/java/com/justspeaktoit/android/cloud/CleanupPolicy.kt`
- **Sunset:** Superseded cleanup models are removed and migrated at once by `CleanupModelRemovals` rather than on a shutdown day ([cleanup model upgrades](cleanup-model-upgrades-2026-11.md)).
- **Nuances:** Android resolves a removed selection through the exported successor map, then the default. When a provider pre-processing prompt is active (AssemblyAI keyterms), LLM cleanup is skipped.

### F08 Local LLM cleanup
- **Platforms:** macOS Yes · iOS Partial · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** iOS, Android #1650 (iOS runs the downloaded models on the CPU only; still open: device speed and memory measurements, and Metal if they show the CPU is too slow. Android has Gemini Nano on phones whose AICore offers it (#1659, device acceptance pending) and the downloaded GGUF models from #1660 in the app; still open: device measurements on #1660, which may let the keyboard run longer cleanups. See [Android on-device models](android-on-device-models.md)).
- **How:** Local cleanup IDs are `local/post-processing/...`; `local/post-processing/rules` is the built-in rules cleanup. A downloaded LLM must receive the user's cleanup prompt as its system instruction. Android's Gemini Nano is the `AndroidLocalModels.geminiNanoID` route (exported as `geminiNano` in `cloud_catalog.json`): ML Kit's GenAI Prompt API sends the shared `TranscriptCleanupPolicy` instruction (or the user's prompt) as the system instruction and the transcript as separate JSON data, checks `countTokens` against the 4,000-token input limit first, and runs only while the app is the top foreground app. It is listed under **On this phone** in the cleanup picker only where `checkStatus()` reports it available or downloadable; elsewhere the picker says why. Downloaded llama.cpp models are listed in the same section once downloaded, and choosing one replaces the picked cloud model or Gemini Nano; choosing any other model in the picker clears it.
- **Refs:** `Sources/SpeakCore/LocalModels/LocalPostProcessingModel.swift`, `Sources/SpeakCore/ModelCatalog+LocalModels.swift`, `Sources/SpeakDesktop/Transcription/DesktopPostProcessing.swift`, `Sources/SpeakWindows/WindowsLocalCleanup.swift`, `Sources/SpeakLinux/LinuxLocalCleanup.swift`, `Sources/SpeakCore/LlamaCppAndroidExport.swift`, `android/app/src/main/cpp/llama_jni.cpp`, `android/app/src/main/java/com/justspeaktoit/android/local/LlamaCppCleaner.kt`, `android/app/src/main/java/com/justspeaktoit/android/dictation/DownloadedCleanup.kt`, `Sources/SpeakCore/LocalModels/AndroidLocalModels.swift`, `android/app/src/main/java/com/justspeaktoit/android/ondevice/GeminiNanoCleanup.kt`, `android/app/src/main/java/com/justspeaktoit/android/ondevice/MlKitGeminiNano.kt`, `android/app/src/main/java/com/justspeaktoit/android/ui/GeminiNanoViews.kt`, `Sources/CLlamaRuntime/jsti_llama_runtime.cpp`, `Sources/SpeakiOSLlama/LlamaRuntimeCleanupEngine.swift`, `Sources/SpeakiOS/LocalModels/IOSLocalCleanupModels.swift`, `Sources/SpeakiOS/LocalModels/IOSLocalCleanupModelManager.swift`, `Sources/SpeakiOS/Views/Settings/IOSDownloadedCleanupModelsList.swift`, `Sources/SpeakCore/LocalModels/LocalCleanupPrompt.swift`
- **Sunset:** none
- **Nuances:** Rules cleanup ignores the prompt; the UI must say so. Desktop runtime notes: [desktop local LLM cleanup](desktop-local-llm-cleanup.md). iOS can't reuse the macOS path: `Sources/CLlamaCpp` vendors headers only and `LlamaCpp.cpp` `dlopen`s a separately provisioned shared library, and the macOS direct build installs a Python sidecar. On iOS the runtime may not be downloaded or loaded from outside the app (App Store guideline 2.5.2), so iOS compiles the pinned llama.cpp source (the same b11425 archive Android pins) into the app as the `CLlamaRuntime` target, CPU only with Accelerate, and downloads only the GGUF weights, which are data. iOS offers the same three pins with the same 5 GiB floor for Qwen3 1.7B (`ProcessInfo.physicalMemory`) under **On-Device Cleanup Models** in Post-Processing › Model & Prompt; downloaded ones also appear in the cleanup model picker. It sends the cleanup prompt (`LocalCleanupPrompt`, shared with macOS) as the SYSTEM message and the transcript as USER, loads the model for each cleanup and frees it afterwards, and a memory warning stops a running cleanup. Failures keep the original transcript with the reason, never a cloud or rules fallback. The iOS keyboard extension never loads a model: keyboard handoffs are polished in the app. Android builds llama.cpp from a pinned source archive into the app's own native library, sharing one ggml with whisper.cpp, and downloads only the SmolLM2 360M, Qwen3 0.6B and Qwen3 1.7B pins (`LlamaCppModels`, exported to `cleanup_models.json`; Qwen3 1.7B only on phones with 5 GiB or more). Choosing a downloaded model in Settings › Clean up transcripts (or under **On this phone** in the cleanup picker) replaces the picked cleanup model; a profile's own cleanup model still wins for its sessions, and a profile can choose a downloaded model from the same picker (its `local/post-processing/*` ID is stored in the profile; a missing model fails visibly with the original kept). A model that is missing, fails its size and SHA-256 check, times out (two minutes) or thinks aloud keeps the original transcript, with no cloud or rules fallback. Small models sometimes echo the `{"transcript": ...}` wrapper, which Android and iOS unwrap; the desktop does not. The keyboard cleans up with the profile's or the user's downloaded model only (never a cloud model or Gemini Nano, and never for a voice edit): the words show as composing text while it runs, and `KeyboardLocalModels.cleanupFits` first estimates load, hashing, prompt and reply time against 8 of the keyboard's 10 seconds, so SmolLM2 runs for about 230 characters, Qwen3 0.6B only for a few words once its weights are hashed, and Qwen3 1.7B never. A cleanup that would not fit, runs past 10 seconds or fails types the words as said, with the reason shown. The weights are hashed in the background when the keyboard opens, and one process-wide lock keeps the app and keyboard from loading two models at once. Android Gemini Nano never falls back to a cloud model: background use (`BACKGROUND_USE_BLOCKED`), `BUSY`, the per-app battery quota, an over-limit or cut-short request and an empty reply all keep the original transcript with the reason shown, and an empty transcript never calls the model. The keyboard is never the top app, so voice edit maps Gemini Nano to the default cloud cleanup model (`VoiceEditPolicy`). AICore refuses phones with an unlocked bootloader.

### F09 Custom cleanup prompt
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** The prompt is an instruction; the transcript is content, never instructions. Show the editor for remote and downloaded local LLMs alike.
- **Refs:** `Sources/SpeakApp/PostProcessing/PostProcessingPromptBuilder.swift`, `Sources/SpeakApp/Views/Settings/CleanupPromptPreview.swift`, `Sources/SpeakDesktop/Transcription/DesktopPostProcessing.swift`, `Sources/SpeakCore/TranscriptCleanupPolicy.swift`, `android/app/src/main/java/com/justspeaktoit/android/cloud/CleanupPolicy.kt`
- **Sunset:** none
- **Nuances:** Provider transcription prompts (OpenAI `prompt`, AssemblyAI keyterms) bias vocabulary only; tone and formatting belong in this cleanup prompt.

### F10 Browse OpenRouter models picker
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Bundled models first, then live-discovered OpenRouter models after an explicit opt-in; selecting one saves its slug and adds it to the picker. Pickers list native-provider models, then a separate **Browse OpenRouter models…** button; the browser searches, filters by provider and zero listed prices, and opens a details page (pricing, context, speed, strengths) before **Use this model**. Browser copy, item ordering and filter rules live in `OpenRouterModelBrowserCatalog` and `OpenRouterBrowserFilter` (SpeakCore). Android consumes them through the `openRouterBrowser` section of the exported `cloud_catalog.json` (copy, bundled cleanup and transcription rows, vendor names and both discovery endpoints) plus a Kotlin port of the filter, both checked against `Tests/Fixtures/openrouter-browser/`; `OpenRouterDiscovery.kt` ports the discovery parsing, cache and fallback rules. Windows and Linux render pages that `DesktopOpenRouterBrowser` (SpeakDesktop) builds from the same catalogue and filter, through the `OpenRouterBrowser.h` query the host registers at startup; the native dialogs (Win32 and GTK) only draw rows and return the chosen picker slot.
- **Refs:** `Sources/SpeakCore/AppleUI/OpenRouterCleanupBrowser.swift`, `Sources/SpeakCore/AppleUI/OpenRouterModelBrowser.swift`, `Sources/SpeakCore/AppleUI/OpenRouterTranscriptionBrowser.swift`, `Sources/SpeakCore/OpenRouter/OpenRouterModelBrowserCatalog.swift`, `android/app/src/main/java/com/justspeaktoit/android/cloud/CleanupModelPicker.kt`, `android/app/src/main/java/com/justspeaktoit/android/cloud/OpenRouterBrowser.kt`, `android/app/src/main/java/com/justspeaktoit/android/cloud/OpenRouterDiscovery.kt`, `android/app/src/main/java/com/justspeaktoit/android/ui/CleanupModelPickerDialog.kt`, `android/app/src/main/java/com/justspeaktoit/android/ui/TranscriptionModelPickerDialog.kt`, `Sources/SpeakDesktop/Transcription/DesktopOpenRouterBrowser.swift`, `Sources/CWindowsSupport/WindowsOpenRouterBrowser.cpp`, `Sources/CLinuxSupport/LinuxOpenRouterBrowser.c`
- **Sunset:** `CleanupModelDiscoveryView` is deprecated in favour of `OpenRouterCleanupBrowser` (`Sources/SpeakCore/AppleUI/CleanupModelDiscoveryView.swift`); delete it in the next declared breaking API change.
- **Nuances:** Streaming pickers have no browse button because OpenRouter can't stream ([OpenRouter audio](openrouter-audio.md)). Discovery behaviour: [cleanup model discovery](cleanup-model-discovery.md). On Windows and Linux the button sits beside the cleanup picker (Remote source) and the transcription picker (Remote Batch only); the browser offers only models the picker can select (bundled entries plus models discovered after opt-in), and choosing one selects that picker entry, labelled `OpenRouter › name`. Unlike macOS, those pickers still list OpenRouter routes inline (after the direct-provider routes), because the native picker owns the slot the browser selects. Cleanup choices take effect on Apply in the Post-processing dialog, as other picker edits do. Per-profile model pickers have no browse button yet on Windows and Linux. Android has no streaming cloud picker; its cloud model list shows direct-provider models, then **Browse OpenRouter models…**, which lists the bundled OpenRouter audio models followed by every audio-input model OpenRouter lists today (refreshed when the browser opens and the cached list is over six hours old; the last list is used for up to seven days, and only the bundled models when there is none) and sends recordings to OpenRouter's `/audio/transcriptions`. Its cleanup browser has the same opt-in **Discover OpenAI cleanup models via OpenRouter** switch as iOS. Profile model pickers on Android use the same browsers.

### F11 Dictation profiles
- **Platforms:** macOS Yes · iOS Limited · Windows Yes · Linux Yes · Android Limited
- **Excluded:** none
- **Gaps:** none
- **How:** A profile matches the frontmost app and overrides model, prompt, vocabulary and output for that session; validate with the shared rules.
- **Refs:** `Sources/SpeakCore/Recording/DictationProfileValidation.swift`, `Sources/SpeakDesktop/Profiles/DesktopDictationProfileStore.swift`, `Sources/SpeakDesktopHost/Settings/DesktopHostProfiles.swift`, `Sources/SpeakApp/Session/SessionProfileApplier.swift`, `Sources/SpeakCore/Desktop/LinuxProfileMatching.swift`, `Sources/SpeakCore/Recording/DictationProfile.swift`, `android/app/src/main/java/com/justspeaktoit/android/settings/DictationProfiles.kt`
- **Sunset:** none
- **Nuances:** iOS can't see the frontmost app, so profiles apply through keyboard handoff and Focus filters (F44). Android can't either; the user picks the active profile in the app or the keyboard's profile key. Linux app matching depends on what the compositor exposes.

### F12 Vocabulary, corrections, pronunciation
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Vocabulary biases recognition (sent as the provider's keyterms or prompt when its catalogue entry accepts one); corrections rewrite final text, and an automatic correction also restores the stored spelling's case when the recogniser already writes the word ("kubernetes" → "Kubernetes"). Limits come from `TranscriptionKeywordPolicy`.
- **Refs:** `Sources/SpeakCore/Vocabulary/PersonalLexiconStore.swift`, `Sources/SpeakDesktop/Vocabulary/DesktopVocabulary.swift`, `Sources/SpeakDesktopHost/Transcription/DesktopHostVocabulary.swift`, `Sources/SpeakApp/PostProcessing/PersonalCorrectionsView.swift`, `Sources/SpeakCore/Vocabulary/KeyboardCorrectionWatcher.swift`, `Sources/SpeakCore/Keyboard/Apple/KeyboardCorrectionObserver.swift`, `Sources/SpeakCore/Keyboard/Apple/KeyboardCorrectionStore.swift`, `Sources/SpeakiOS/Services/IOSLearnedCorrections.swift`, `Sources/SpeakiOS/Views/Settings/LearnedCorrectionsView.swift`, `android/app/src/main/java/com/justspeaktoit/android/corrections/PersonalCorrections.kt`, `android/app/src/main/java/com/justspeaktoit/android/readaloud/Pronunciation.kt`, `Sources/SpeakCore/DataMigrationVocabularyCatalog.swift`
- **Sunset:** none
- **Nuances:** AssemblyAI keyterms are capped (50 characters each, 100 items). Corrections apply to every final path: app, keyboard, import and History retry. The pronunciation dictionary rewrites text only before read aloud (F21), never the transcript. Android's starting entries come from SpeakCore through `voice_catalog.json`, and its entries transfer as the shared migration catalogue's `pronunciation` records, merged by id or word. Only a regular expression's replacement is a template; a word's replacement is said literally on every platform. Android's regex engine cannot be interrupted, so it runs each expression off the main thread with a time limit and skips one that ran past it from then on.

### F13 Transcription language selection
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Automatic by default; the choice reaches every recogniser, keyboard and cloud route. Use the shared language list.
- **Refs:** `Sources/SpeakCore/Capture/CaptureParameters.swift`, `Sources/SpeakApp/Settings/AppSettings+TranscriptionSelection.swift`, `Sources/SpeakDesktopHost/Transcription/DesktopHostTranscription.swift`, `android/app/src/main/java/com/justspeaktoit/android/dictation/DictationLanguages.kt`
- **Sunset:** none
- **Nuances:** OpenAI `gpt-live-transcribe`/`gpt-transcribe` take plural `languages`; older OpenAI models take singular `language`. Android's list is exported in `cloud_catalog.json`.

### F14 History list and search
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Every capture, including failures and cancellations, lands in History with friendly model names; search covers raw and processed text.
- **Refs:** `Sources/SpeakCore/History/HistoryPresentation.swift`, `Sources/SpeakDesktop/History/DesktopHistorySearch.swift`, `Sources/SpeakDesktopHost/History/DesktopHostHistory.swift`, `Sources/SpeakApp/History/HistoryManager.swift`, `android/app/src/main/java/com/justspeaktoit/android/history/History.kt`, `android/app/src/main/java/com/justspeaktoit/android/history/HistoryFilter.kt`
- **Sunset:** none
- **Nuances:** iOS persistence rules: [iOS History persistence](ios-history-persistence.md). Cancelled recordings: [cancelled recordings](cancelled-recordings.md).

### F15 History filters (model, errors, dates)
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Filters narrow the visible list by model, error state and date; they never change stored entries.
- **Refs:** `Sources/SpeakDesktop/History/DesktopHistoryFilter.swift`, `Sources/SpeakApp/History/HistoryListModel.swift`, `Sources/SpeakWindows/WindowsHistoryFilters.swift`, `Sources/SpeakLinux/LinuxHistoryFilters.swift`, `Sources/SpeakiOS/Views/HistoryFilterSheet.swift`, `Sources/SpeakiOS/Views/HistoryViewDerivedState.swift`, `android/app/src/main/java/com/justspeaktoit/android/history/HistoryFilter.kt`
- **Sunset:** none
- **Nuances:** Every platform uses the shared day policy (`HistorySearchQuery.normalizedDayRange`): whole local calendar days, inclusive, and an end before the start means the start day only; Android mirrors it in Kotlin with tests. Android filters by Cloud model or by recognition mode (On-device, Speech service), counts a kept recording whose later transcription failed as an error, and lets either date end stay open. iOS filters by the entry's transcription model and its recorded error. Wrapped GTK checkbox labels must be created explicitly (`Sources/CLinuxSupport/LinuxHistoryFilters.c`).

### F16 History retry and audio playback
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Retry re-runs transcription from the retained recording; playback uses the original audio when it still exists.
- **Refs:** `Sources/SpeakDesktop/History/DesktopHistoryRetry.swift`, `Sources/SpeakDesktopHost/History/DesktopHostPlayback.swift`, `Sources/SpeakApp/Views/HistoryAudioPlayback.swift`, `android/app/src/main/java/com/justspeaktoit/android/dictation/HistoryRetry.kt`, `android/app/src/main/java/com/justspeaktoit/android/ui/HistoryAudioPlayer.kt`
- **Sunset:** none
- **Nuances:** Windows playback notes: [Windows History playback](windows-history-playback.md). Android deletes a transcribed Cloud recording unless **Keep recordings in History** (`keepRecordingsInHistory`, off by default) is on; Speech service sessions have no recording. Android recordings live only inside History, so its Clear History "Keep recordings" keeps the entries that hold audio, where desktop keeps the files on disk.

### F17 History sync
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Apple platforms use CloudKit; Windows, Linux and Android use CloudKit Web Services with the same record shape. A synced copy keeps its `originPlatform`; a local or imported record leaves it nil. Android is a Kotlin port of `SpeakDesktopSync` (opt-in sign-in through the browser and the same loopback callback, deletion tickets, tombstones and the comparison pass); records are audio-free on every platform.
- **Refs:** `Sources/SpeakSync/HistoryChangeReconciler.swift`, `Sources/SpeakDesktopSync/DesktopHistorySyncStore.swift`, `Sources/SpeakDesktopHost/History/DesktopHostCloudSync.swift`, `Sources/SpeakApp/App/AppCloudSync.swift`, `Sources/SpeakWindows/WindowsCloudSync.swift`, `android/app/src/main/java/com/justspeaktoit/android/sync/`
- **Sunset:** iPhone has moved into the shared `iCloud.com.justspeaktoit` container with a one-time migration from the legacy iPhone container. After the #1119 device checks pass on Stable, drop the legacy entitlement entry, `SyncContainerFamily.iOS`, the migration, the deprecated `SyncConfiguration.legacyFamily` properties and the `IOS_SHARED_CLOUD_CONTAINER` variable ([shared container](cloudkit-shared-container.md)).
- **Nuances:** Never set `originPlatform` on migration imports: `removeSyncedCopy` may delete audio-free records that carry it. Mac/iPhone sync stays unqualified until the #1119 checks pass; the direct-download Mac build has no CloudKit entitlement yet ([Windows CloudKit sync](windows-cloudkit-sync.md)). Android sync needs the `CLOUDKIT_WEB_API_TOKEN` secret in the main-only `android-release` environment, which `android.yml` and `alpha-release.yml` pass to the build (#1741, #1827); the Windows build reads the same secret from the `cloudkit` environment; without it Settings says sync is not set up. Android cannot check which app opened the loopback callback, so it relies on the browser checks alone. The API token's registered callback is `https://justspeaktoit.com/cloudkit-sign-in` (CloudKit Console refuses `http://`); the site's Worker forwards only the token with a 302 to the loopback `http://127.0.0.1:47823/cloudkit-sign-in`, so desktop and Android sign-in needs justspeaktoit.com up (#1815).

### F18 Settings search
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Every setting, card and page is an entry in `SettingsSearchCatalog` whose title equals the on-screen heading; hosts project it.
- **Refs:** `Sources/SpeakCore/SettingsSearch/SettingsSearchCatalog.swift`, `Sources/SpeakCore/SettingsSearch/DesktopSettingsSearch.swift`, `Sources/SpeakiOS/Views/Settings/IOSSettingsSearch.swift`, `android/app/src/main/java/com/justspeaktoit/android/settings/SettingsSearch.kt`
- **Sunset:** none
- **Nuances:** Coverage tests fail on unindexed settings (`Tests/SpeakAppTests/SettingsSearchCoverageTests.swift`). Regenerate `android/app/src/main/assets/settings_search.json` after changing Android entries ([settings search](settings-search.md)).

### F19 Command palette
- **Platforms:** macOS Yes · iOS N/A · Windows Yes · Linux Yes · Android N/A
- **Excluded:** iOS, Android (OS: no keyboard-first desktop shell; mobile uses settings search and system Shortcuts).
- **Gaps:** none
- **How:** One keyboard-first "Search for anything" palette (⌘K on the Mac, Ctrl+K or Ctrl+F on Windows and Linux) over the actions the host can run, then matching History, then settings; an empty query lists every action, recent History and recent then suggested settings. Ranking lives once in SpeakCore's `CommandPaletteSearch` (actions in `CommandPaletteAction.catalogue`); Windows and Linux use `DesktopCommandPaletteSession` over a `CommandPaletteHistorySnapshot` that the host's History refresh fills. Choosing an action runs it as its shortcut does; choosing a History record selects it on the History page.
- **Refs:** `Sources/SpeakCore/CommandPalette/CommandPaletteSearch.swift`, `Sources/SpeakCore/CommandPalette/CommandPaletteAction.swift`, `Sources/SpeakCore/CommandPalette/DesktopCommandPaletteSession.swift`, `Sources/SpeakApp/Views/CommandPalette/CommandPaletteCommand.swift`, `Sources/SpeakApp/Views/Settings/SettingsSearchPalette.swift`, `Sources/SpeakWindows/WindowsCommandPalette.swift`, `Sources/SpeakLinux/LinuxSettingsSearch.swift`
- **Sunset:** none
- **Nuances:** The Mac passes no History to the shared search, so its palette lists actions and settings only. Desktop palettes offer only shortcut actions their host can run, so Copy Last Transcript is Mac-only; no palette lists actions on another app's selection, since the palette has focus. On Windows and Linux the palette reuses the sidebar's settings search box and native events (`JSTI_EVENT_SETTINGS_SEARCH*`); rows keep stable `commandPaletteResult.*` and `settingsSearchResult.*` automation IDs. `Sources/CLinuxSupport/LinuxDesktopPalette.c` is a colour palette for theming, not a command palette.

### F20 Compare models
- **Platforms:** macOS Yes · iOS N/A · Windows Yes · Linux Yes · Android N/A
- **Excluded:** iOS, Android (owner decision: Compare models is desktop-only; #1622 closed as not planned).
- **Gaps:** none
- **How:** Run several models on the same audio, shown in a blind order the user ranks before names are revealed; saving results to History is opt-in.
- **Refs:** `Sources/SpeakDesktop/Comparison/DesktopComparisonRunner.swift`, `Sources/SpeakDesktopHost/Comparison/DesktopHostComparison.swift`, `Sources/SpeakApp/CompareModels/CompareModelsController.swift`, `Sources/SpeakWindows/WindowsComparison.swift`, `Sources/SpeakLinux/LinuxComparison.swift`
- **Sunset:** none
- **Nuances:** Comparisons are raw: no vocabulary seeding or automatic insertion. Don't add mobile UI for it.

### F21 Voice output / read aloud
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Read a transcript or selection with the chosen provider and voice from the shared TTS catalogue; validate voice options before sending.
- **Refs:** `Sources/SpeakCore/TTS/Desktop/DesktopSpeechSynthesis.swift`, `Sources/SpeakDesktopHost/ReadAloud/DesktopHostReadAloud.swift`, `Sources/SpeakApp/TextToSpeech/TextToSpeechManager.swift`, `Sources/SpeakiOS/Services/VoiceOutputRouter.swift`, `android/app/src/main/java/com/justspeaktoit/android/ui/ReadAloudButton.kt`, `android/app/src/main/java/com/justspeaktoit/android/readaloud/ReadAloudController.kt`, `android/app/src/main/java/com/justspeaktoit/android/readaloud/CloudSpeechSynthesizer.kt`, `android/app/src/main/java/com/justspeaktoit/android/readaloud/AccountVoices.kt`, `android/app/src/main/java/com/justspeaktoit/android/readaloud/RealtimeSpeech.kt`, `Sources/SpeakCore/TTS/VoiceCatalogAndroidExport.swift`, `Sources/SpeakCore/TTS/VoiceCatalogAndroidExport+Accounts.swift`
- **Sunset:** OpenAI `/v1/audio/speech` TTS models shut down 2027-01-06 (`ModelRetirements`). ElevenLabs `elevenlabs/rachel|adam|bella` IDs migrate (`ElevenLabsTTSCatalog.legacyVoiceIdentifiers`). `SonioxTTSTextChunker` is a deprecated alias of `TTSTextChunker`, removed at the next major release.
- **Nuances:** Desktop SSML is capped at 64 KiB and never split. Groq PlayAI voices retired on 2025-12-31 and must not return (`Sources/SpeakCore/GroqTTSCatalog.swift`). Voice settings transfer atomically on desktop hosts ([desktop voice sources](desktop-voice-sources.md)). Android reads transcripts and History entries with the phone's voices or the cloud voices in `voice_catalog.json`, exported from SpeakCore and never copied; the export leaves out retiring OpenAI speech models. The export also carries the account listings (Mistral voices, xAI built-in and custom voices and Soniox custom voices: URL, headers, paging and limits) and the OpenAI Realtime session frames and voices, built with SpeakCore's request builders. Android lists account voices with the saved key when the picker opens and shows a failed, oversized or invalid listing instead of a partial one; a chosen account voice is not listed again before reading, so a voice deleted from the account fails with the provider's refusal. Realtime voices refuse a response whose transcript is not a verbatim reading. OpenAI `/v1/audio/speech` voices are N/A on Android because those models shut down 2027-01-06 (`ModelRetirements`); OpenAI Realtime voices cover OpenAI there. A cloud voice uses the provider's saved key. A missing or rejected key, an exhausted quota or a busy speaker is shown, and Android never moves to another voice. Audio focus pauses on a transient loss, resumes only a pause it caused and stops on a permanent loss. xAI account voices are the built-ins from `GET /v1/tts/voices` plus the team's cloned voices from the paginated `GET /v1/custom-voices` (they never appear in the first list); a 403 or 404 on the first custom page means the team has no custom library (#1793), while one on a later page fails the listing. An OpenAI Realtime reading is played only if its transcript has every input word in order, each numeral read as the same digits or English number words, a minus sign read as one word such as "minus", a decimal point read or left out but never heard inside an integer, and extra words only for symbols read aloud, so a changed number, a dropped sign or an inserted "not" is rejected (`Sources/SpeakCore/TTS/Providers/RealtimeReadingCheck.swift`). Android mirrors both: `RealtimeReading` in `RealtimeSpeech.kt` with the exported limits, and an xAI account listing that reads `/v1/tts/voices` and then the `/v1/custom-voices` pages, offering every voice beyond the fixed presets.

### F22 Voice edit of selected text
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Limited · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Capture the selection and its target, dictate an instruction, rewrite with the cleanup model, then replace only in the captured target; never redirect to another field.
- **Refs:** `Sources/SpeakCore/PostProcessing/VoiceEditPolicy.swift`, `Sources/SpeakDesktop/Voice/DesktopVoiceEdit.swift`, `Sources/SpeakDesktopHost/Voice/DesktopHostVoiceEdit.swift`, `Sources/SpeakApp/VoiceEdit/VoiceEditController.swift`, `Sources/SpeakWindows/WindowsVoiceEdit.swift`, `android/app/src/main/java/com/justspeaktoit/android/ime/VoiceEdit.kt`, `android/app/src/main/java/com/justspeaktoit/android/cloud/VoiceEditPolicy.kt`, `Sources/SpeakDesktop/Voice/DesktopVoiceEditTarget.swift`, `Sources/SpeakLinux/LinuxVoiceEdit.swift`, `Sources/CLinuxSupport/LinuxAtspiRequests.c`
- **Sunset:** none
- **Nuances:** Linux is limited by the desktop's accessibility stack: it works only in external editable AT-SPI fields after **Voice Output > Selection access > Allow...**; toolkits without AT-SPI `EditableText` or with no app accessibility show it as unavailable, and Wayland needs a desktop keybinding to `--edit-selection-by-voice`. The Mac rejects missing or cross-process AX targets (`Sources/SpeakApp/Output/AccessibilityTextOutput.swift`). Linux arms one AT-SPI selection lease when the command runs; any focus, caret, selection or text change in that field during dictation aborts the edit and copies the rewrite instead, and a replacement is confirmed by reading back the field. It has no tray item because clicking the tray moves focus off the captured field. Android takes the prompt and formatting words from SpeakCore through `cloud_catalog.json`. Its keyboard Edit key is enabled only while the field reports a selection. It records the instruction with the keyboard's own recogniser and rewrites with the profile's or saved cleanup model and that provider's key, even when cleanup is off. The first Edit in a keyboard session names the provider, which receives only the selection and instruction, and waits for a second tap. Before committing, the keyboard re-reads the field's package, id, selection range and selected text; if any differ or the input restarted, it leaves the text alone and says so.

### F23 Hands-free and silence auto-stop
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Voice activity starts and stops capture; configured silence ends the session through the normal stop path.
- **Refs:** `Sources/SpeakCore/Capture/HandsFreeVoiceActivity.swift`, `Sources/SpeakCore/Capture/Apple/HandsFreeVoiceActivitySession.swift`, `Sources/SpeakDesktopHost/Recording/DesktopHostHandsFree.swift`, `Sources/SpeakApp/Session/HandsFreeDictationCoordinator.swift`, `Sources/SpeakiOS/Services/IOSHandsFreeDictationCoordinator.swift`, `android/app/src/main/java/com/justspeaktoit/android/dictation/SilenceAutoStop.kt`, `android/app/src/main/java/com/justspeaktoit/android/dictation/HandsFreeVoiceActivity.kt`, `android/app/src/main/java/com/justspeaktoit/android/dictation/HandsFreeDictation.kt`
- **Sunset:** none
- **Nuances:** iOS scene lifecycle rules: [iOS hands-free lifecycle](ios-hands-free-scene-lifecycle.md). Android ports `DictationSilenceMonitor` and the SpeakCore level scale for Cloud capture only, with the shared defaults (0.05 threshold, 2 s) and keys; its on-device and speech-service recognisers already end on a pause. Android hands-free (`handsFreeDictationEnabled`) ports `EnergyVoiceActivityDetector` and the 0.5 s pre-roll gate to Kotlin, with a test that reads the Swift constants. It works in Cloud mode only: `SpeechRecognizer` opens its own microphone, so the on-device and speech-service modes cannot receive the buffered pre-roll, and the Settings toggle says so. Between recordings the microphone stays open (level only, nothing recorded or sent) under the foreground service's Listening notification, whose Stop turns hands-free off; silence auto-stop is forced on for each hands-free recording, and leaving the app without the service turns it off.

### F24 Insert text into other apps
- **Platforms:** macOS Yes · iOS Limited · Windows Yes · Linux Limited · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Insert at the captured target with the platform's native API; when the target can't be reached safely, leave the text on the clipboard rather than typing elsewhere, then restore the clipboard only if it is still ours.
- **Refs:** `Sources/SpeakApp/Output/SmartTextOutput.swift`, `Sources/SpeakApp/Output/AccessibilityTextOutput.swift`, `Sources/SpeakDesktopHost/Output/DesktopHostOutput.swift`, `Sources/CWindowsSupport/WindowsTextOutputInsertion.cpp`, `android/app/src/main/java/com/justspeaktoit/android/ime/DictationKeyboardService.kt`
- **Sunset:** none
- **Nuances:** Mac: `kAXSelectedTextAttribute` (insert at cursor) by default, `kAXValueAttribute` (replace all) as fallback; Electron/Chromium apps skip AX. Don't probe AX at recording start. iOS and Android insert only through their keyboards; Linux depends on AT-SPI and portals ([Windows text insertion](windows-text-insertion.md)).

### F25 Recording HUD / live text overlay
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** Android #1592: the foreground-service notification shows state and a Stop action but no live text.
- **How:** Show recording state, level and live text while capturing, and dismiss with the session. iOS uses a Live Activity; Android an ongoing microphone foreground-service notification.
- **Refs:** `Sources/SpeakApp/HUD/HUDManager.swift`, `Sources/SpeakDesktopHost/Output/DesktopHostHUD.swift`, `Sources/CWindowsSupport/WindowsHUD.cpp`, `Sources/CLinuxSupport/LinuxHUD.c`
- **Sunset:** none
- **Nuances:** Providers that retract text need an authoritative transcript snapshot or the Mac drops empty interim callbacks (`Sources/SpeakApp/Live/SharedClientLiveController.swift`).

### F26 Menu bar / tray presence
- **Platforms:** macOS Yes · iOS N/A · Windows Yes · Linux Yes · Android N/A
- **Excluded:** iOS (OS: no menu bar; use Controls and the Live Activity); Android (OS: no tray; use the Quick Settings tile).
- **Gaps:** none
- **How:** A persistent icon shows recording state and offers record, open and quit.
- **Refs:** `Sources/SpeakApp/Services/MenuBarManager.swift`, `Sources/CWindowsSupport/WindowsTray.cpp`, `Sources/CLinuxSupport/LinuxTray.c`
- **Sunset:** none
- **Nuances:** Plain GNOME has no StatusNotifierWatcher, so Linux registers no tray icon there; everything must stay reachable from the window.

### F27 Resources-in-use status
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** List what is actually in use now (microphone, network providers, local models) from runtime state, not configuration.
- **Refs:** `Sources/SpeakCore/SystemResources/SystemResourceRegistry.swift`, `Sources/SpeakApp/SystemResources/SystemResourceMonitor.swift`, `Sources/SpeakWindows/WindowsSystemResources.swift`, `Sources/SpeakLinux/LinuxSystemResources.swift`, `android/app/src/main/java/com/justspeaktoit/android/resources/SystemResources.kt`
- **Sunset:** none
- **Nuances:** See [system resources](system-resources.md).

### F28 Report an issue with diagnostics
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Build a frozen allowlisted report, show the exact bytes, and ask consent per report before copy, export or open.
- **Refs:** `Sources/SpeakCore/History/IssueDiagnosticReport.swift`, `Sources/SpeakApp/History/HistoryIssueReporter.swift`, `Sources/SpeakiOS/Views/IOSIssueReportPreview.swift`, `Sources/SpeakWindows/WindowsIssueReports.swift`, `android/app/src/main/java/com/justspeaktoit/android/diagnostics/IssueReport.kt`
- **Sunset:** none
- **Nuances:** Android mirrors the SpeakCore JSON schema in Kotlin with `platform` `android`, and its History records no stage timings, so its timeline is always empty. Reports never include transcript text, audio, raw errors, logs, keys, persistent IDs or absolute timestamps ([transcript logging](SECURITY_TRANSCRIPT_LOGGING.md)).

### F29 Troubleshooting page
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Check permissions, devices, keys and connectivity, explain each failure and link straight to its fix.
- **Refs:** `Sources/SpeakCore/Desktop/DesktopTroubleshooting.swift`, `Sources/SpeakCore/Troubleshooting/MobileTroubleshooting.swift`, `Sources/SpeakApp/Views/TroubleshootingView.swift`, `Sources/SpeakiOS/Views/Settings/IOSTroubleshootingView.swift`, `Sources/SpeakiOS/Views/CaptureHealthView.swift`, `Sources/SpeakWindows/WindowsTroubleshooting.swift`, `Sources/SpeakLinux/LinuxTroubleshooting.swift`, `Sources/SpeakCore/Troubleshooting/MobileTroubleshootingAndroidExport.swift`, `android/app/src/main/java/com/justspeaktoit/android/diagnostics/Troubleshooting.kt`, `android/app/src/main/java/com/justspeaktoit/android/ui/TroubleshootingSection.kt`
- **Sunset:** none
- **Nuances:** Re-read permission state after the user returns; a click is not proof of a grant. Phones use `MobileTroubleshooting` (microphone and speech permissions, on-device model, missing/rejected/unreadable keys, keyboard Full Access); a key is reported rejected only after Check key asks the provider. Capture Health stays the deeper capture self-test. Android evaluates the same rules from `assets/troubleshooting.json` (exported with `scripts/update-android-assets`, Android wording via `MobileTroubleshooting.Platform.android`) as a Settings section: it has no speech permission or Full Access, has no Check key, so a key is rejected only after a provider returned 401 during dictation, and the mode choice and model download it links to live on the Dictation screen.

### F30 Onboarding and permissions guide
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** First run asks for each permission in context with the native prompt first, then a guide on denial; completion is stored once.
- **Refs:** `Sources/SpeakCore/Desktop/DesktopOnboarding.swift`, `Sources/SpeakApp/Permissions/PermissionSettingsGuide.swift`, `Sources/SpeakiOS/Views/FirstRunOnboardingView.swift`, `Sources/SpeakWindows/WindowsOnboarding.swift`, `Sources/SpeakLinux/LinuxOnboarding.swift`, `android/app/src/main/java/com/justspeaktoit/android/ui/OnboardingScreen.kt`
- **Sunset:** none
- **Nuances:** Mac guide rules per permission: [Mac permission guides](mac-permission-guides.md). Android stores completion under the same `hasCompletedOnboarding` key and re-runs from Settings > Setup guide; installs that already chose a mode or allowed the microphone skip it. The Dictate tile is offered in a system dialog on Android 13+, with instructions on older versions.

### F31 API keys page
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Keys go only to secure storage (Keychain service `com.github.speakapp.credentials`, Windows Credential Manager, Secret Service, Android Keystore); the UI shows set/unset and validation, never the value.
- **Refs:** `Sources/SpeakCore/Credentials/Apple/SecureStorage.swift`, `Sources/SpeakDesktopHost/Credentials/DesktopHostAPIKeys.swift`, `Sources/SpeakApp/Views/Settings/SettingsView+APIKeys.swift`, `Sources/SpeakWindows/WindowsAPIKeys.swift`, `android/app/src/main/java/com/justspeaktoit/android/security/KeystoreSecretStore.kt`
- **Sunset:** none
- **Nuances:** Guidance per provider: [API key guidance](api-key-guidance.md). Tests use a disposable Keychain (`scripts/with-test-keychain.py`).

### F32 Provider credit balances
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Read-only balance beside each provider's primary key card, for providers that expose one; others state why and link to billing. Checks run on page open, after a save and on Check balance, never block key entry and never show or log the key.
- **Refs:** `Sources/SpeakCore/Balance/ProviderBalance.swift`, `Sources/SpeakCore/Balance/ProviderBalanceDirectory.swift`, `Sources/SpeakCore/Balance/ProviderBalanceSources.swift`, `Sources/SpeakCore/AppleUI/ProviderBalanceView.swift`, `Sources/SpeakDesktopHost/Credentials/DesktopProviderBalances.swift`, `Sources/CWindowsSupport/WindowsAPIKeysPage.cpp`, `Sources/CLinuxSupport/LinuxAPIKeys.c`, `android/app/src/main/java/com/justspeaktoit/android/cloud/ProviderBalanceStore.kt`
- **Sunset:** none
- **Nuances:** See [provider balances](provider-balances.md). Android's account list is exported from SpeakCore (`provider_balances.json`); a new readable account needs a Kotlin client or `ProviderBalancesTest` fails. Android reads Deepgram, ElevenLabs, OpenRouter and Rev AI (`android/app/src/main/java/com/justspeaktoit/android/cloud/ProviderBalances.kt`); its other providers link to billing.

### F33 Configuration export/import and backup
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Inspect an archive, stage it, then apply only valid categories; absent or damaged categories keep existing data. API keys travel only when the user explicitly includes them.
- **Refs:** `Sources/SpeakCore/DataMigration/DataMigrationPlanner.swift`, `Sources/SpeakDesktop/Migration/DesktopMigrationArchive.swift`, `Sources/SpeakApp/DataMigration/MigrationPlanner.swift`, `Sources/SpeakiOS/Views/ConfigTransferView.swift`, `Sources/SpeakDesktop/Migration/DesktopMigrationRestoreConfiguration.swift`, `Sources/SpeakDesktopHost/Migration/DesktopHostMigrationConfiguration.swift`, `Sources/SpeakLinux/LinuxMigrationRestore.swift`, `android/app/src/main/java/com/justspeaktoit/android/transfer/ConfigImporter.kt`
- **Sunset:** Legacy saved model references are rewritten on import (`Sources/SpeakApp/DataMigration/MigrationModelReferences.swift`).
- **Nuances:** Never turn a missing category into an empty replacement. Android writes and reads the same version-2 ZIP; it merges rather than replaces, imports only WAV recordings, carries its own mode, retention, prompt and active profile in `android-settings.json`, and skips (with a notice) connections, model references, pronunciations and settings it has no equivalent for. API keys travel only when chosen on export and again on import. Windows and Linux restore every category in one all-or-nothing step after a preview; model files are never copied (the preview names the ones to download), Mac pairing details are skipped, and native-only choices (active model, appearance, run at login, automation permission) stay as they are. See [configuration transfer](configuration-transfer.md) and [data migration](data-migration.md).

### F34 Raw settings editor and config tools
- **Platforms:** macOS Yes · iOS Partial · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** iOS, Android #1608 (iOS and Android have no automation server for the config tools).
- **How:** One JSON document of canonical keys with all-or-nothing validation, no secrets, and keys for other platforms preserved; the same document backs `speak config` and the MCP configuration tools.
- **Refs:** `Sources/SpeakCore/Automation/AutomationConfiguration.swift`, `Sources/SpeakCore/SettingsConfiguration/SettingsSchema+Desktop.swift`, `Sources/SpeakDesktopHost/Automation/DesktopHostAutomationConfiguration.swift`, `Sources/SpeakDesktopHost/Settings/DesktopHostRawConfiguration.swift`, `Sources/CWindowsSupport/WindowsRawConfiguration.cpp`, `Sources/CLinuxSupport/LinuxRawConfiguration.c`, `Sources/SpeakiOS/Views/Settings/IOSRawConfigurationEditorView.swift`, `android/app/src/main/java/com/justspeaktoit/android/settings/RawConfiguration.kt`, `Sources/SpeakApp/Views/Settings/RawConfigurationEditorView.swift`, `Sources/SpeakApp/Transport/AppAutomationHandler+Configuration.swift`
- **Sunset:** none
- **Nuances:** The desktop Preferences editor (`Sources/SpeakDesktopHost/Settings/DesktopHostConfigurationEditor.swift`) is a typed form, not this feature. The iPhone's Read aloud keys (#1671) share the Mac's `ttsSpeed`, `ttsLanguageIdentifier` and `sonioxTTSRegion` definitions (`SettingsSchema+VoiceOutput.swift`); its provider, model, voice and speed are checked together by `VoiceOutputProvider.selectionProblems`. They have no iPhone Settings page, so they are not in Settings search on iOS. The Windows and Linux raw editor windows only edit text and pick files; the shared host validates and saves, and read-only keys (this computer's automation grant and consents) are kept with a warning.

### F35 Automation (CLI, MCP, App Intents)
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Limited
- **Excluded:** none
- **Gaps:** none
- **How:** Off until the user enables it; the `speak` CLI and MCP talk to an app-owned Unix socket or named pipe and drive the normal dictation path. iOS uses App Intents and Shortcuts.
- **Refs:** `Sources/SpeakCore/Automation/AutomationCommandDispatch.swift`, `Sources/SpeakDesktopHost/Automation/DesktopHostAutomation.swift`, `Sources/SpeakApp/Transport/AutomationServer.swift`, `Sources/SpeakCLI`, `android/app/src/main/java/com/justspeaktoit/android/surfaces/DictateTileService.kt`
- **Sunset:** none
- **Nuances:** Android has the tile and launcher shortcut only, with no CLI by design. See [automation](automation.md).

### F36 Usage insights dashboard
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Limited
- **Excluded:** none
- **Gaps:** none
- **How:** Derive everything on the device from History; nothing is sent. Usage totals (sessions, errors, recording time, average length, words) use `HistoryPresentationStatistics`'s rules over every History entry. Speech insights run `SpeechInsightsEngine` over completed entries with text, analysed on the raw transcript (the cleaned text only as a fallback), via `SpeechSessionRecord(historyRecord:)`; Apple platforms hold the persisted aggregate in the shared `SpeechInsightsModel`. Android reads the definitions (fillers, stopwords, limits, pace ranges) from `speech_insights.json`, exported from SpeakCore by `scripts/update-android-assets`, and mirrors the engine and tokenizer in Kotlin.
- **Refs:** `Sources/SpeakCore/SpeechInsights/SpeechInsightsEngine.swift`, `Sources/SpeakCore/SpeechInsights/SpeechInsightsModel.swift`, `Sources/SpeakCore/SpeechInsights/SpeechSessionRecord+History.swift`, `Sources/SpeakCore/SpeechInsights/SpeechInsightsAndroidExport.swift`, `Sources/SpeakDesktop/History/DesktopHistoryPresentation.swift`, `Sources/SpeakApp/Views/Dashboard/SpeechInsightsDashboard.swift`, `Sources/SpeakiOS/Views/UsageInsightsView.swift`, `android/app/src/main/java/com/justspeaktoit/android/history/SpeechInsights.kt`, `android/app/src/main/java/com/justspeaktoit/android/ui/InsightsScreen.kt`, `Tests/Fixtures/speech-insights/parity.json`
- **Sunset:** none
- **Nuances:** Android is limited by the platform: top words, vocabulary, trending words and word of the month need SpeakCore's NaturalLanguage lemmas, which Android has no equivalent for; the Kotlin tokenizer splits on spaces and punctuation only, so an unspaced Chinese or Japanese run counts as one word, lowering words, phrases and pace for those languages. Android's ICU dictionary segments differently from NaturalLanguage and the JVM tests cannot run it, so no shared fixture could hold the two to the same words. `Tests/Fixtures/speech-insights/parity.json` is the shared fixture: `SpeechInsightsParityTests` (Swift) regenerates its `expected` block with `UPDATE_SPEECH_INSIGHTS_PARITY=1` and `SpeechInsightsParityTest` (Kotlin) must produce the same numbers. The Kotlin tokenizer mirrors NaturalLanguage for dictated prose: clitics split off ("can't" is "ca" + "n't"), and dotted abbreviations keep their full stop only away from the end of the text. iOS and Android History record no cost, so they show no spend. "Time saved" is not shown on any platform.

### F37 Opt-in analytics and crash reporting
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Nothing is sent until the user opts in; crash events are scrubbed before upload. Withdrawing consent drops queued analytics events (cancelling one in flight) and deletes queued crash reports without sending them. Windows and Linux show two separate General settings, both off, and keep the choice in the device-local `telemetry.json`, never in exported, imported or automation-written preferences. They send over the host's existing HTTPS transport (WinHTTP, URLSession) with a bounded in-memory queue and drop failures; crash reports cover fatal top-level errors and a previous session that did not shut down cleanly, from release builds only. Windows and Linux release workflows stamp the PostHog project key (`scripts/desktop-analytics/configure-posthog-key.py`) into builds from pushes to main and Alpha/Stable manifest tags only; pull request, branch and manual main builds are keyless and send no PostHog product analytics. Sentry crash diagnostics are separate and can still send from a release build once the user grants diagnostics consent. Both Windows and Linux settings are searchable (`DesktopSettingsSearchTests`).
- **Refs:** `Sources/SpeakCore/Analytics/ProductAnalytics.swift`, `Sources/SpeakApp/Analytics/AnalyticsLocalPolicy.swift`, `Sources/SpeakApp/Analytics/PostHogAnalytics.swift`, `Sources/SpeakApp/Analytics/SentryManager.swift`, `Sources/SpeakApp/Analytics/SentryEventScrubber.swift`, `android/app/src/main/java/com/justspeaktoit/android/telemetry/ProductAnalytics.kt`, `android/app/src/main/java/com/justspeaktoit/android/telemetry/SentryCrashReporter.kt`, `Sources/SpeakCore/Desktop/DesktopTelemetryConsent.swift`, `Sources/SpeakDesktop/Telemetry/DesktopTelemetry.swift`, `Sources/SpeakDesktop/Telemetry/DesktopTelemetryScrubber.swift`, `Sources/SpeakDesktopHost/Telemetry/DesktopHostTelemetryHTTP.swift`
- **Sunset:** none
- **Nuances:** Sentry is EU-hosted; PostHog covers product events only ([analytics plan](analytics-plan.md), [PostHog maintenance](posthog-maintenance.md)). The desktop consent keys are `desktopAnalyticsConsent` and `desktopDiagnosticsConsent`, distinct from the Mac's `analyticsEnabled` and the Apple/Android string `analyticsConsent`/`diagnosticsConsent`, so a transferred Mac or phone preference never opts a desktop in.

### F38 Tip jar / paid access
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** The tip jar uses StoreKit, and Google Play Billing consumables with the same product IDs on Android. Windows and Linux (like the direct-download Mac build) show the canonical `TipWebLink` list from SpeakCore, GitHub Sponsors and Ko-fi, in About's Support development; the tipper chooses the amount in the browser and nothing unlocks. Paid access proxies requests through a Cloudflare Worker (`workers/paid-access`) that holds vendor keys, so subscribers need no API keys; it is entitlement-checked at routing time.
- **Refs:** `Sources/SpeakApp/App/TipStore.swift`, `Sources/SpeakApp/Views/TipJarView.swift`, `Sources/SpeakApp/PaidAccess/PaidAccessManager.swift`, `workers/paid-access`, `android/app/src/main/java/com/justspeaktoit/android/tips/PlayBillingTipStore.kt`, `Sources/SpeakCore/TipCatalog.swift` (`TipWebLink`), `Sources/SpeakDesktopHost/Native/DesktopNativeLists.swift` (`configureTipJar`), `Sources/CWindowsSupport/WindowsWindowAbout.cpp`, `Sources/CLinuxSupport/LinuxWindowSettingsPages.c`
- **Sunset:** Paid access stays compiled dark (`TUIST_PAID_ACCESS`) on every platform until the owner launches it ([paid access](paid-access.md), #648); Windows, Linux and Android gain it then, through the same worker. Windows tips stay web links rather than a Microsoft Store add-on so the sideloaded and Store builds match.
- **Nuances:** Use `@ObservedObject` for `TipStore.shared`, never `@StateObject`. Stale preferences can't enable paid access in a public build. Android thanks the user only after Play confirms the consume, and retries a failed one so the tier can be bought again and isn't refunded. Keep `TipWebLink` in step with `.github/FUNDING.yml`. Desktop tips are web links because the paid-access worker has no tip route: its Stripe checkout sells a subscription behind Sign in with Apple.

### F39 Audio file import
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Imported audio runs through the normal batch path and lands in History.
- **Refs:** `Sources/SpeakDesktopHost/Recording/DesktopHostAudioImport.swift`, `Sources/SpeakApp/History/HistoryLibraryActions.swift`, `Sources/SpeakiOS/Services/SharedRecordingImporter.swift`, `android/app/src/main/java/com/justspeaktoit/android/dictation/SharedAudioImporter.kt`
- **Sunset:** The iOS Share extension is Alpha-only behind `TUIST_IOS_SHARE_EXTENSION` until the owner approves it.
- **Nuances:** The app drains the Share extension's App Group inbox whether or not the extension is built.

### F40 Launch at login
- **Platforms:** macOS Yes · iOS N/A · Windows Yes · Linux Yes · Android N/A
- **Excluded:** iOS, Android (OS: mobile apps don't launch at login).
- **Gaps:** none
- **How:** Use the OS login-item mechanism and show its real state.
- **Refs:** `Sources/SpeakDesktop/Shell/DesktopLoginItem.swift`, `Sources/SpeakDesktopHost/Settings/DesktopHostLoginItem.swift`, `Sources/SpeakWindows/WindowsLoginItemHost.swift`, `Sources/SpeakLinux/LinuxLoginItemHost.swift`
- **Sunset:** none
- **Nuances:** Flatpak needs the Background portal on Linux.

### F41 Updates
- **Platforms:** macOS Yes · iOS N/A · Windows Yes · Linux Yes · Android N/A
- **Excluded:** iOS, Android (OS: store-managed updates).
- **Gaps:** none
- **How:** Mac uses Sparkle with per-train, per-architecture appcasts; Windows uses MSIX App Installer for the sideloaded package and the Microsoft Store for the Store package; Linux uses the Flatpak repository. Alpha and Stable are separate trains; only Stable is offered to existing installs.
- **Refs:** `Sources/SpeakApp/Services/UpdaterManager.swift`, `Sources/SpeakApp/Services/UpdateFeedSelection.swift`, `Docs/windows-installer.md`, `Docs/linux-packaging.md`
- **Sunset:** Every Mac build still ships the legacy universal `appcast.xml` feed so old installs keep updating (`UpdateFeedSelection.legacyFeedURL`); keep it.
- **Nuances:** Never offer an arm64-only update to Intel or Rosetta. Store submission happens only after Stable publication (`.github/workflows/windows-store.yml`). See [release trains](alpha-stable-release-trains.md).

### F42 Microphone selection
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** The chosen device applies when the next input session begins; otherwise the OS default is used. Label it as a preference, not the measured route (#852).
- **Refs:** `Sources/SpeakApp/Audio/AudioInputDeviceManager.swift`, `Sources/SpeakWindows/WindowsMicrophones.swift`, `Sources/SpeakLinux/LinuxMicrophoneMonitor.swift`, `Sources/SpeakiOS/Services/AudioSessionManager+PreferredInput.swift`, `Sources/SpeakCore/Capture/PreferredAudioInput.swift`, `android/app/src/main/java/com/justspeaktoit/android/cloud/AudioInputs.kt`
- **Sunset:** none
- **Nuances:** See [Windows microphone discovery](windows-microphone-discovery.md). iOS lists `AVAudioSession.availableInputs` (built-in, wired, Bluetooth, USB) and applies the choice with `setPreferredInput` after the recording session activates, waiting up to 500 ms for the route before capture starts. A missing choice falls back to the system route and the recording screen says so; keyboard readiness's held session is never re-routed. Android lists built-in, wired and USB inputs, plus Bluetooth headsets from Android 12 (their microphone needs `setCommunicationDevice`, cleared when the recording stops), and routes each Cloud recording with `AudioRecord.setPreferredDevice`. Android's device ids change on every connection, so the saved `preferredAudioInputUID` is built from type, address and product name. A missing choice records from the default, and Settings and the dictation screen say so. Android's on-device and speech service recognisers open the microphone themselves and cannot be routed, so the choice applies to Cloud recordings.

### F43 Recording start/stop sounds
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Play the chosen cue on start and stop only, never on intermediate events, cancel or failure.
- **Refs:** `Sources/SpeakCore/Recording/Apple/RecordingSoundPlayer.swift`, `Sources/SpeakDesktopHost/Recording/DesktopHostRecordingFeedback.swift`, `Sources/SpeakiOS/Services/TranscriptionRecordingService.swift`, `android/app/src/main/java/com/justspeaktoit/android/dictation/RecordingSoundPlayer.kt`
- **Sunset:** none
- **Nuances:** Apple preloads bundled sound files so the cue plays instantly. Android preloads the same files (copied byte for byte into `res/raw`) into a SoundPool, records silence over the start cue in Cloud mode and plays Stop only after the microphone has stopped; it has no haptics.

### F44 Per-app output target (profiles) / Focus overrides
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Limited · Android N/A
- **Excluded:** Android (OS: a keyboard always inserts into the focused field).
- **Gaps:** none
- **How:** Output method and target follow the matched profile; iOS uses Focus filters instead of app detection.
- **Refs:** `Sources/SpeakApp/Output/TextOutputTarget.swift`, `Sources/SpeakDesktopHost/Output/DesktopHostAppSwitchOutput.swift`, `Sources/SpeakiOS/Activity/DictationFocusFilter.swift`, `Sources/SpeakLinuxPlatform/LinuxTextOutput.swift`
- **Sunset:** none
- **Nuances:** Linux app detection depends on the Wayland compositor. See [Focus capture overrides](focus-capture-overrides.md).

### F45 Recording audio housekeeping
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** Android #1629 (deletes cloud audio after upload, so nothing is retained).
- **How:** Keep recordings per the retention setting and delete temporary audio on finish or cancel.
- **Refs:** `Sources/SpeakDesktopHost/Recording/DesktopHostAudioCleanup.swift`, `Sources/SpeakApp/Audio/AudioFileManager.swift`, `Sources/SpeakiOS/Services/TranscriptionRecordingService+Finalisation.swift`
- **Sunset:** none
- **Nuances:** Clean up audio resources started before any failing guard (stop the engine, remove the tap).

### F46 Send transcripts from phone to desktop
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** The Mac, Windows and Linux run a user-enabled, paired, encrypted WebSocket receiver (`SpeakTransportWire` v2 over Bonjour/DNS-SD) that pastes each received final transcript at the cursor. A sender browses for the train's Bonjour service, pairs once with the six-digit code the receiver shows, keeps the issued device credential in secure storage, and authenticates every later send with that credential only. Each send is one connection: one final chunk, wait for the receiver's acknowledgement, disconnect, and show success or the failure. Senders reuse `SendToMacSender`, `MacDiscovery` and `MacConnection.deliverTranscript`. Receivers share the handshake, pairing store, v2 crypto and session (`TransportReceiverSession`); the desktops add `DesktopTransportReceiver` (WebSocket framing, sealed state, accept loop) and `DesktopHostPhoneReceiver` (Settings actions, insertion through the normal output path), and supply only a TCP listener, a DNS-SD advertiser and the Settings card. Android ports the sender to Kotlin (package `com.justspeaktoit.android.sendtomac`): it browses with `NsdManager`, keeps the credential in its Keystore-encrypted `SecretStore` (`sendToMac.pairing`, never backed up or exported), and reads the service type, labels, sizes and frame limits from `send_to_mac_protocol.json`, which SpeakCore exports (`SendToMacProtocolAndroidExport`) with handshake and message test vectors.
- **Refs:** `Sources/SpeakCore/Sync/Transport/TransportReceiverSession.swift`, `Sources/SpeakCore/Sync/Transport/TransportPortableHandshake.swift`, `Sources/SpeakCore/Sync/Transport/TransportReceiverPairingStore.swift`, `Sources/SpeakCore/Sync/Transport/Crypto/PortableChaChaPoly.swift`, `Sources/SpeakCore/Sync/Apple/SendToMacSender.swift`, `Sources/SpeakCore/Sync/Apple/MacDiscovery.swift`, `Sources/SpeakCore/Sync/Apple/SendToMacPairingStore.swift`, `Sources/SpeakCore/Sync/Apple/MacConnection.swift`, `Sources/SpeakCore/Sync/Apple/TransportChannel.swift`, `Sources/SpeakDesktop/Transport/DesktopTransportReceiver.swift`, `Sources/SpeakDesktopHost/Output/DesktopHostPhoneReceiver.swift`, `Sources/SpeakWindows/WindowsPhoneReceiver.swift`, `Sources/CWindowsSupport/WindowsPhoneTransport.cpp`, `Sources/CWindowsSupport/WindowsPhoneReceiverSettings.cpp`, `Sources/SpeakLinux/LinuxPhoneReceiver.swift`, `Sources/CLinuxSupport/LinuxPhoneReceiver.c`, `Sources/SpeakApp/Transport/TransportServer.swift`, `Sources/SpeakApp/App/WireUp+SendToMac.swift`, `Sources/SpeakApp/Transport/SendToMacAvailability.swift`, `Sources/SpeakiOS/Views/Settings/SendToMacSettingsRows.swift`, `Sources/SpeakiOS/Views/HistoryView.swift`, `Sources/SpeakCore/Sync/Transport/TransportProtocolConstants.swift`, `Sources/SpeakCore/Sync/Apple/SendToMacProtocolAndroidExport.swift`, `android/app/src/main/java/com/justspeaktoit/android/sendtomac/SendToMacClient.kt`, `android/app/src/main/java/com/justspeaktoit/android/ui/SendToMacSection.kt`, `Docs/MACOS_RECEIVER.md`
- **Sunset:** none
- **Nuances:** Never fall back to the pairing code after pairing: a revoked credential is an error until the user forgets the Mac and pairs again (#1643). The credential lives in its own Keychain item so iCloud key sync and the configuration QR code never carry it. There is no automatic send of each finished transcript: Polish rewrites text after finalisation, background App Intents may lack the local network, and the keyboard already inserts its text; the hook would be `publishHandoff` in the iOS finalisation. A Mac that is asleep or has the receiver off fails the send after ten seconds; nothing is queued. Handoff ("Continue on Mac") and History sync remain separate paths. The iOS app needs `NSLocalNetworkUsageDescription` and its train's service in `NSBonjourServices`; the archive verifier checks both. v1 plaintext peers are refused. Android's Kotlin port must stay byte-identical: `SendToMacProtocolVectorTest` and `SendToMacClientTest` replay SpeakCore's vectors, so change the Swift protocol, regenerate the asset (`scripts/update-android-assets`) and fix Kotlin together. Android sends `releaseTrain: stable` and browses only the Stable service, so it pairs with the Stable Mac from justspeaktoit.com; an Alpha Mac refuses it. It needs no permission at target SDK 36; targeting 37 will need `ACCESS_LOCAL_NETWORK`. The receiver ships only in the direct macOS build: the Mac App Store build has no `network.server` entitlement or Bonjour service and hides Send to Mac (`SendToMacAvailability`). Windows and Linux: off by default; the on/off choice, the pairing code and device credentials live in a sealed file (`PhoneReceiver/state.sealed`) whose key is in Credential Manager or the Secret Service keyring, never in `settings.json`, so a restored Mac backup cannot open a listener. Received transcripts are typed where the focus is when they arrive, through the normal output path, and are not added to History. Desktop builds advertise the Stable service type only (`_speaktransport._tcp`), so they pair with Stable iOS builds. Windows announces through `DnsServiceRegister` (Windows 10 1903 or later; older builds show why), and Windows Firewall may ask on first listen; allow private networks. Linux announces through avahi-daemon over the system bus (the Flatpak holds `--system-talk-name=org.freedesktop.Avahi` for this) and shows an error when it is not running; a name another host already uses, found while Avahi probes, is replaced by Avahi's alternative ("Name #2"), which Settings shows, but a clash after the probe succeeds is not re-resolved. The iOS app still labels the list "Send to Mac", so a PC appears there under its computer name.

### F47 Accessible names, IDs and recording announcements
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Every control has a name, role, state and stable automation ID; recording start, stop and errors are announced.
- **Refs:** `scripts/accessibility/check-apple-accessibility.py`, `scripts/accessibility/check-linux-accessibility.py`, `android/app/src/main/java/com/justspeaktoit/android/ui/AutomationIds.kt`, `Docs/accessibility.md`
- **Sunset:** none
- **Nuances:** `make lint` enforces the Apple rules; suppress only with `// a11y-ignore: reason`. Owner passes are tracked in #1399.

### F48 Learned auto-corrections
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Limited
- **Excluded:** none
- **Gaps:** none
- **How:** Watch the field after inserting; when the same edit recurs it is promoted to a correction rule (F12). Platforms supply only field monitoring.
- **Refs:** `Sources/SpeakCore/Vocabulary/Apple/AutoCorrectionEngine.swift`, `Sources/SpeakApp/PostProcessing/AutoCorrectionTracker.swift`, `Sources/SpeakDesktopHost/Controller/DesktopHostController.swift`, `Sources/SpeakApp/PostProcessing/PersonalCorrectionsView.swift`, `android/app/src/main/java/com/justspeaktoit/android/corrections/AutoCorrectionLearning.kt`, `android/app/src/main/java/com/justspeaktoit/android/ime/KeyboardCorrectionObserver.kt`
- **Sunset:** none
- **Nuances:** iOS learns through the Just Speak Keyboard (#1651): after it inserts a transcript it remembers the text either side, and when it next appears (iOS gives an extension no callbacks while another keyboard is up) it diffs the text now between that context with the shared `CorrectionSpan`/`WordDiffer`. Only the changed words cross the App Group (`KeyboardCorrectionStore`); the app records them through `AutoCorrectionDomain` and applies learned rules to every finished transcript. Edits made without the keyboard, in password fields or after 10 minutes are not learned. iOS has no Personal corrections page, so Settings › Post-Processing › Auto-Corrections lists learned rules and candidates for removal. iOS automatic polish is separate cleanup. Desktops share `DesktopHostCorrectionLearning`. Android mirrors `WordDiffer` and the learning policy in Kotlin (`WordDifferParityTest` pins shared cases; change both together). Its keyboard reads only the field it typed into, while it is still in that field, between the text remembered either side of the insertion; switching to another keyboard ends the watch. Password, no-suggestion and no-personalised-learning fields are never read. Promoted edits join Personal corrections; dismissed suggestions stay hidden.

### F49 Appearance settings
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** System, light or dark; System is stored as no override.
- **Refs:** `Sources/SpeakDesktopHost/Settings/DesktopHostSettings.swift`, `Sources/SpeakApp/Settings/AppSettings+System.swift`, `Sources/SpeakiOS/Views/Settings/IOSSettingsPage.swift`, `android/app/src/main/java/com/justspeaktoit/android/settings/AppAppearance.kt`
- **Sunset:** none
- **Nuances:** Linux reads only a declarative palette file, never theme scripts (`Sources/CLinuxSupport/LinuxDesktopPalette.c`). Android also offers wallpaper (dynamic) colours on Android 12 and later, and has no density setting.

### F50 Keyboard / IME surface
- **Platforms:** macOS N/A · iOS Yes · Windows N/A · Linux N/A · Android Yes
- **Excluded:** macOS, Windows, Linux (OS: desktops insert directly via hotkeys, F01 and F24).
- **Gaps:** none
- **How:** iOS: the keyboard hands off to the app to record, then inserts the result on return. When the app's Instant Dictation session is not running, the mic key reads Connect and opens the app through `KeyboardConnectLink`, which starts the session; recording starts when the keyboard reappears. Android: an IME records and commits into the focused field. It uses on-device recognition or the speech service unless the user opts in to live Cloud models (Settings > Dictation keyboard, `keyboardLiveCloudEnabled`, off by default; #1668): then, with Cloud chosen and a live model, it streams through the app's own session controller and `cloud/live` clients (`KeyboardLiveDictation`), reading the key in process, shows partials as composing text and commits the corrected final text.
- **Refs:** `Sources/SpeakCore/Keyboard/Apple/KeyboardHandoff.swift`, `Docs/ios-keyboard-v2-design.md`, `android/app/src/main/java/com/justspeaktoit/android/ime/DictationKeyboardService.kt`, `Docs/android-input-surfaces.md`
- **Sunset:** `TUIST_IOS_KEYBOARD_DIRECT_CAPTURE` is an experiment (#661); Apple gives custom keyboards no microphone. `KeyboardHandoff.legacyRecordKey` (v3) is still read for migration.
- **Nuances:** The iOS app runs on iPad: name the device through `DeviceCopy`, never "iPhone" (`Sources/SpeakiOS/Views/DeviceCopy.swift`). iOS keyboards cannot call `UIApplication.shared` or use `extensionContext.open`, so `JustSpeakKeyboard/ContainingAppOpener.swift` opens the app through the responder chain's `openURL:options:completionHandler:`; a plain "open the app" prompt is not enough, because opening the app only restarts Instant Dictation once it has been enabled. Android's live Cloud keyboard never falls back: a batch Cloud model, a missing key, a stream failure or a finish past the keyboard's 10-second bound (`KeyboardPolicy.FINISH_TIMEOUT_MS`) fails visibly and types nothing, and no on-device or speech-service recogniser is tried instead. It watches calls, audio focus and headset changes with the app's own `SessionInterruptionWatch` and `InterruptionPolicy`: a brief focus loss pauses it (the status line says Paused) and a call, lasting focus loss or headset change ends it visibly. When an explicit on-device or speech-service choice is unusable the keyboard says so and never blames Cloud (`KeyboardPolicy.blamesBatchCloud`). Voice edit (F22) still hears its instruction on the phone. Keyboard sessions skip History and cleanup (`SessionHistory.None`).

### F51 Consent before sharing with cloud AI providers
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** App Store guideline 5.1.2(i) and Google Play's User Data policy need explicit permission before personal data goes to a third-party AI service (#1805). Before the first send of a data kind (audio, transcript text, text to speak) to a provider that has not been allowed on this device, a dialog names each provider, lists what it would get and why, and links its privacy policy. Its buttons are **Allow**, **Use on-device instead** (only for a new recording that an on-device recogniser or no cleanup can handle) and **Not now**. Nothing is recorded or sent until the user answers. On Android, Allow runs the send that waited; on Apple platforms the user starts again. A saved recording (History retry, shared or imported audio, watch captures) stays where it was so the user can retry. On macOS Voice Edit asks before it records the spoken instruction, for the transcription and the rewrite providers. Existing users get the dialog once at their next recording rather than a silent failure. Settings › Privacy lists the providers allowed, each with **Withdraw**. Surfaces that cannot ask (the Android keyboard and its Voice Edit, iOS Shortcuts and App Intents, the Action Button, the keyboard hand-off started in the background, and macOS automation) send nothing and say why with `CloudSharingConsent.blockedMessage`, which tells the user to open the app; the Android keyboard also opens it. Shared and imported audio stays queued until consent is given. Requests come from `PrivacyWorkflowSummary` and `CloudSharingConsent.requests(for:)`, keyed by the canonical provider ID in `CloudSharingProviderCatalogue`. On Windows and Linux (#1814) the host asks before every upload path: recording start, History retry, imported audio, remote cleanup, live Auto-Clean, read-aloud and voice export, Compare and Voice Edit. The dialog offers **Allow** and **Not now** only (desktop has no one-click on-device switch; the status line points to on-device models), and the user starts the work again after Allow. Settings › About › Privacy settings lists the providers allowed, each with **Withdraw**. Windows and Linux automation (`speak`) never opens the dialog: it sends nothing and says why.
- **Refs:** `Sources/SpeakCore/App/CloudSharingConsent.swift`, `Sources/SpeakCore/AppleUI/CloudSharingConsentSheet.swift`, `Sources/SpeakApp/Session/MainManager+CloudSharingConsent.swift`, `Sources/SpeakApp/Settings/AppSettings+CloudSharing.swift`, `Sources/SpeakiOS/Services/IOSCloudSharingConsentPrompt.swift`, `Sources/SpeakiOS/Views/IOSCloudSharingConsentPresenter.swift`, `android/app/src/main/java/com/justspeaktoit/android/cloud/CloudSharingConsent.kt`, `android/app/src/main/java/com/justspeaktoit/android/dictation/CloudSharingGate.kt`, `android/app/src/main/java/com/justspeaktoit/android/ui/CloudSharingViews.kt`, `Sources/SpeakDesktop/Shell/DesktopCloudSharingConsentStore.swift`, `Sources/SpeakDesktopHost/Controller/DesktopHostCloudSharing.swift`, `Sources/CWindowsSupport/include/CloudSharing.h`, `Sources/CWindowsSupport/WindowsCloudSharing.cpp`, `Sources/CLinuxSupport/LinuxCloudSharing.c`
- **Sunset:** none
- **Nuances:** Consent is per device: it lives under the `cloudSharingConsent` key (UserDefaults on Apple, SharedPreferences on Android, the same JSON on both) and is never synced, exported or imported, so a transferred configuration asks again. Android reads the copy, kinds and provider list from `cloud_catalog.json` (`CloudCatalogAndroidExport`), never a hand-kept list. A provider missing from `CloudSharingProviderCatalogue` still needs consent: it is shown by name without a policy link, so add new providers to the catalogue. The platform speech services (Apple Speech, Android `SpeechRecognizer`) are covered by the OS's own permission and disclosure and are not gated here. Journey and UI test fixtures pre-allow their providers. Windows and Linux keep it in `cloud-sharing-consent.json` beside the settings (the same JSON, never exported, migrated or synced); an unreadable file allows nothing. `DesktopHostConnectionPreWarming` sends no content and is not gated. Host tests build controllers with `DesktopHostController.consented`; consent tests construct the controller directly.

## Companion surfaces

### W01 watchOS companion
Starts and stops capture on the watch, queues recordings for transfer to the
iPhone and shows state in a complication. Gated by `TUIST_WATCH_APP` (Alpha
only) until the owner approves it for Stable. Refs:
`Sources/SpeakWatchCore/WatchRecordingLifecycle.swift`,
`Sources/SpeakWatchCore/WatchCaptureProtocol.swift`, [watch provisioning](watch-provisioning.md).
It uses its own App Group (`group.com.justspeaktoit.watch`); without it,
storage falls back to Application Support and the complication shows idle.
