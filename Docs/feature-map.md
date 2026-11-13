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
| F03 | Live streaming cloud transcription | Yes | Yes | Yes | Yes | Partial | #1590 | Android partials come only from the platform recogniser. |
| F04 | Batch cloud provider catalogue | Yes | Yes | Yes | Yes | Partial | #1636 | Android lists a subset. |
| F05 | Downloaded local transcription models | Yes | No | Yes | Yes | No | #1650 | iOS has Apple on-device only (F06). |
| F06 | Platform on-device recogniser | Yes | Yes | N/A | N/A | Yes | | |
| F07 | Remote cleanup (OpenRouter and native LLMs) | Yes | Yes | Yes | Yes | Yes | | |
| F08 | Local LLM cleanup | Yes | No | Yes | Yes | No | #1650 | |
| F09 | Custom cleanup prompt | Yes | Yes | Yes | Yes | Yes | | |
| F10 | Browse OpenRouter models picker | Yes | Yes | No | No | Partial | #1618 | Android: searchable cleanup list only. |
| F11 | Dictation profiles | Yes | Limited | Yes | Yes | Limited | | iOS and Android cannot see the frontmost app. |
| F12 | Vocabulary, corrections, pronunciation | Yes | Yes | Yes | Yes | Partial | #1626 | Android: corrections only. Corrections also restore the stored spelling's case. |
| F13 | Transcription language selection | Yes | Yes | Yes | Yes | Yes | | |
| F14 | History list and search | Yes | Yes | Yes | Yes | Yes | | |
| F15 | History filters (model, errors, dates) | Yes | Yes | Yes | Yes | Yes | | Android filters by Cloud model or recognition mode. |
| F16 | History retry and audio playback | Yes | Yes | Yes | Yes | Yes | | Android keeps recordings only when "Keep recordings in History" is on. |
| F17 | History sync | Yes | Yes | Yes | Yes | No | #1630 | Desktops use CloudKit Web Services. |
| F18 | Settings search | Yes | Yes | Yes | Yes | Yes | | |
| F19 | Command palette | Yes | N/A | No | No | N/A | #1619 | |
| F20 | Compare models | Yes | N/A | Yes | Yes | N/A | #1622 | Desktop-only by owner decision. |
| F21 | Voice output / read aloud | Yes | Yes | Yes | Yes | Partial | #1631 | Android: system TTS only. |
| F22 | Voice edit of selected text | Yes | Yes | Yes | No | No | #1620 | |
| F23 | Hands-free and silence auto-stop | Yes | Yes | Yes | Yes | Partial | #1632 | Android: Cloud silence auto-stop only; no hands-free. |
| F24 | Insert text into other apps | Yes | Limited | Yes | Limited | Yes | | |
| F25 | Recording HUD / live text overlay | Yes | Yes | Yes | Yes | Partial | #1592 | Android shows an ongoing foreground-service notification with Stop, but no live text. |
| F26 | Menu bar / tray presence | Yes | N/A | Yes | Yes | N/A | | |
| F27 | Resources-in-use status | Yes | Yes | Yes | Yes | Yes | | |
| F28 | Report an issue with diagnostics | Yes | Yes | Yes | Yes | Yes | | |
| F29 | Troubleshooting page | Yes | Yes | Yes | Yes | No | #1634 | Phone rules shared in SpeakCore; Android to port them. |
| F30 | Onboarding and permissions guide | Yes | Yes | Yes | Yes | Yes | | |
| F31 | API keys page | Yes | Yes | Yes | Yes | Yes | | |
| F32 | Provider credit balances | Yes | Yes | No | No | No | #1621 | |
| F33 | Configuration export/import and backup | Yes | Yes | Partial | Partial | No | #1635 | |
| F34 | Raw settings editor and config tools | Yes | Partial | Partial | Partial | Partial | #1608 | iOS and Android have the raw JSON editor but no automation server, so no config tools. Windows and Linux have `speak config` and MCP `get_configuration`/`set_configuration`; no raw JSON editor window yet (#1670). |
| F35 | Automation (CLI, MCP, App Intents) | Yes | Yes | Yes | Yes | Limited | | |
| F36 | Usage insights dashboard | Yes | No | Yes | Yes | Partial | #1623 | Android: 7-day card on History. |
| F37 | Opt-in analytics and crash reporting | Yes | Yes | No | No | Yes | #1624 | |
| F38 | Tip jar / paid access | Yes | Yes | No | No | Partial | #1625 | Paid access is compiled dark. Android: tip jar only. |
| F39 | Audio file import | Yes | Yes | Yes | Yes | Yes | | |
| F40 | Launch at login | Yes | N/A | Yes | Yes | N/A | | |
| F41 | Updates | Yes | N/A | Yes | Yes | N/A | | |
| F42 | Microphone selection | Yes | Partial | Yes | Yes | No | #1637 | |
| F43 | Recording start/stop sounds | Yes | Yes | Yes | Yes | Yes | | |
| F44 | Per-app output target (profiles) / Focus overrides | Yes | Yes | Yes | Limited | N/A | | |
| F45 | Recording audio housekeeping | Yes | Yes | Yes | Yes | Partial | #1629 | |
| F46 | Send transcripts from phone to desktop | Yes | Partial | No | No | No | #1640 | iOS: Handoff and History sync, no direct sender. macOS: direct build only; the Mac App Store build has no receiver. |
| F47 | Accessible names, IDs and recording announcements | Yes | Yes | Yes | Yes | Yes | | |
| F48 | Learned auto-corrections | Yes | No | Yes | Yes | Limited | #1651 | Android learns only from edits made while its keyboard is in the field. |
| F49 | Appearance settings | Yes | Yes | Yes | Yes | Yes | | |
| F50 | Keyboard / IME surface | N/A | Yes | N/A | N/A | Yes | | |

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
- **Gaps:** Android #1590 (cloud partials).
- **How:** Shared provider clients in `SpeakCore/Live` own protocol, readiness, framing and finish sequencing; platform adapters only feed PCM and render text. Interim text replaces the current turn; only finals commit. Change the shared client, not an adapter.
- **Refs:** `Sources/SpeakCore/Live/Providers`, `Sources/SpeakCore/LiveModelCapabilities.swift`, `Sources/SpeakApp/Live/SharedClientLiveController.swift`, `Sources/SpeakDesktop`, `android/app/src/main/java/com/justspeaktoit/android/dictation/AndroidSpeechEngine.kt`
- **Sunset:** OpenAI GPT-4o streaming models shut down 2027-02-26 and Mistral Voxtral Realtime 2027-04-30 (`ModelRetirements`). Saved AssemblyAI Universal-3.5 Pro streaming IDs migrate to Universal-3.6 Pro (`AssemblyAIModels.legacyUniversal3StreamingIDs` in `Sources/SpeakCore/Transcription/Providers/AssemblyAIModels.swift`).
- **Nuances:** OpenRouter cannot stream transcription, so it never appears in streaming pickers ([OpenRouter audio](openrouter-audio.md)). Provider-specific protocol rules (AssemblyAI, OpenAI Realtime, xAI) are in AGENTS.md. Install audio taps only with `installTapSafely`.

### F04 Batch cloud provider catalogue
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** Android #1636 (OpenAI and Groq only).
- **How:** One catalogue (`ModelCatalog`) lists batch providers and models; platforms show a filtered projection of routes their host can run. Saved IDs are `provider/model`.
- **Refs:** `Sources/SpeakCore/ModelCatalog.swift`, `Sources/SpeakCore/Batch/BatchTranscriptionRouting.swift`, `Sources/SpeakCore/CloudCatalogAndroidExport.swift`, `Sources/SpeakiOS/Settings/AppSettings+Models.swift`, `android/app/src/main/java/com/justspeaktoit/android/cloud/CloudCatalog.kt`
- **Sunset:** OpenAI `whisper-1` and GPT-4o transcribe models 2027-02-26, `mistral/voxtral-mini-latest` 2027-04-30 and OpenRouter `openai/gpt-audio` 2027-01-20 (`ModelRetirements`). Legacy AssemblyAI and ElevenLabs batch IDs migrate (`legacyUniversal3BatchIDs`, `legacyElevenLabsBatchIDs`).
- **Nuances:** iOS calls the shared SpeakCore clients for Deepgram, AssemblyAI, ElevenLabs, Groq, Mistral, Modulate, Rev AI, Soniox and Speechmatics (`BatchTranscriptionRouting.iosSharedClientProviderIDs`, `Sources/SpeakiOS/Services/IOSBatchTranscriptionClient+SharedProviders.swift`), each with the provider's own key. Android's catalogue is generated; `CloudCatalogParityTest` fails when it drifts from the export (`android/app/src/test/java/com/justspeaktoit/android/cloud/CloudCatalogParityTest.kt`). Catalogue membership alone is not support: a platform lists only routes it implements. A provider with several engines behind one endpoint pins the engine per ID: Reson8's Rumble-2 and Resonant-1 batch and streaming IDs each send their own `model` and check their own language list (`Sources/SpeakCore/Batch/Reson8Model.swift`); Android has no Reson8 route (#1636).

### F05 Downloaded local transcription models
- **Platforms:** macOS Yes · iOS No · Windows Yes · Linux Yes · Android No
- **Excluded:** none
- **Gaps:** iOS, Android #1650 (Android plan: whisper.cpp, #1658; see [Android on-device models](android-on-device-models.md)).
- **How:** Downloaded models use `local/...` IDs and stay separate from Apple Speech (`apple/local/...`). Show catalogue source, size, downloaded/prepared state and runtime install state; hide runtime install controls once installed.
- **Refs:** `Sources/SpeakCore/ModelCatalog+LocalModels.swift`, `Sources/SpeakCore/LocalModels/LocalModelIdentity.swift`, `Sources/SpeakApp/LocalModels/LocalModelManager.swift`, `Sources/SpeakDesktopHost/LocalModels/DesktopHostLocalModelHost.swift`
- **Sunset:** none
- **Nuances:** Resolve imported model IDs to friendly names everywhere (History, headers). A model in use can't be removed mid-recording (`Sources/SpeakDesktopHost/LocalModels/DesktopHostLocalModelRemoval.swift`). iOS filters `local/...` models out of its pickers (`Sources/SpeakiOS/Settings/AppSettings+Models.swift`); its only on-device route is Apple Speech (F06).

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
- **Platforms:** macOS Yes · iOS No · Windows Yes · Linux Yes · Android No
- **Excluded:** none
- **Gaps:** iOS, Android #1650 (Android plan: Gemini Nano #1659 and llama.cpp #1660; see [Android on-device models](android-on-device-models.md)).
- **How:** Local cleanup IDs are `local/post-processing/...`; `local/post-processing/rules` is the built-in rules cleanup. A downloaded LLM must receive the user's cleanup prompt as its system instruction.
- **Refs:** `Sources/SpeakCore/LocalModels/LocalPostProcessingModel.swift`, `Sources/SpeakCore/ModelCatalog+LocalModels.swift`, `Sources/SpeakDesktop/Transcription/DesktopPostProcessing.swift`, `Sources/SpeakWindows/WindowsLocalCleanup.swift`, `Sources/SpeakLinux/LinuxLocalCleanup.swift`
- **Sunset:** none
- **Nuances:** Rules cleanup ignores the prompt; the UI must say so. Desktop runtime notes: [desktop local LLM cleanup](desktop-local-llm-cleanup.md).

### F09 Custom cleanup prompt
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** The prompt is an instruction; the transcript is content, never instructions. Show the editor for remote and downloaded local LLMs alike.
- **Refs:** `Sources/SpeakApp/PostProcessing/PostProcessingPromptBuilder.swift`, `Sources/SpeakApp/Views/Settings/CleanupPromptPreview.swift`, `Sources/SpeakDesktop/Transcription/DesktopPostProcessing.swift`, `Sources/SpeakCore/TranscriptCleanupPolicy.swift`, `android/app/src/main/java/com/justspeaktoit/android/cloud/CleanupPolicy.kt`
- **Sunset:** none
- **Nuances:** Provider transcription prompts (OpenAI `prompt`, AssemblyAI keyterms) bias vocabulary only; tone and formatting belong in this cleanup prompt.

### F10 Browse OpenRouter models picker
- **Platforms:** macOS Yes · iOS Yes · Windows No · Linux No · Android Partial
- **Excluded:** none
- **Gaps:** Windows, Linux, Android #1618.
- **How:** Bundled models first, then live-discovered OpenRouter models after an explicit opt-in; selecting one saves its slug and adds it to the picker.
- **Refs:** `Sources/SpeakCore/AppleUI/OpenRouterCleanupBrowser.swift`, `Sources/SpeakCore/AppleUI/OpenRouterModelBrowser.swift`, `Sources/SpeakCore/AppleUI/OpenRouterTranscriptionBrowser.swift`, `android/app/src/main/java/com/justspeaktoit/android/cloud/CleanupModelPicker.kt`
- **Sunset:** `CleanupModelDiscoveryView` is deprecated in favour of `OpenRouterCleanupBrowser` (`Sources/SpeakCore/AppleUI/CleanupModelDiscoveryView.swift`); delete it in the next declared breaking API change.
- **Nuances:** Streaming pickers have no browse button because OpenRouter can't stream ([OpenRouter audio](openrouter-audio.md)). Discovery behaviour: [cleanup model discovery](cleanup-model-discovery.md).

### F11 Dictation profiles
- **Platforms:** macOS Yes · iOS Limited · Windows Yes · Linux Yes · Android Limited
- **Excluded:** none
- **Gaps:** none
- **How:** A profile matches the frontmost app and overrides model, prompt, vocabulary and output for that session; validate with the shared rules.
- **Refs:** `Sources/SpeakCore/Recording/DictationProfileValidation.swift`, `Sources/SpeakDesktop/Profiles/DesktopDictationProfileStore.swift`, `Sources/SpeakDesktopHost/Settings/DesktopHostProfiles.swift`, `Sources/SpeakApp/Session/SessionProfileApplier.swift`, `Sources/SpeakCore/Desktop/LinuxProfileMatching.swift`, `Sources/SpeakCore/Recording/DictationProfile.swift`, `android/app/src/main/java/com/justspeaktoit/android/settings/DictationProfiles.kt`
- **Sunset:** none
- **Nuances:** iOS can't see the frontmost app, so profiles apply through keyboard handoff and Focus filters (F44). Android can't either; the user picks the active profile in the app or the keyboard's profile key. Linux app matching depends on what the compositor exposes.

### F12 Vocabulary, corrections, pronunciation
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** Android #1626 (corrections and vocabulary prompt only; no pronunciation).
- **How:** Vocabulary biases recognition (sent as the provider's keyterms or prompt when its catalogue entry accepts one); corrections rewrite final text, and an automatic correction also restores the stored spelling's case when the recogniser already writes the word ("kubernetes" → "Kubernetes"). Limits come from `TranscriptionKeywordPolicy`.
- **Refs:** `Sources/SpeakCore/Vocabulary/PersonalLexiconStore.swift`, `Sources/SpeakDesktop/Vocabulary/DesktopVocabulary.swift`, `Sources/SpeakDesktopHost/Transcription/DesktopHostVocabulary.swift`, `Sources/SpeakApp/PostProcessing/PersonalCorrectionsView.swift`, `android/app/src/main/java/com/justspeaktoit/android/corrections/PersonalCorrections.kt`
- **Sunset:** none
- **Nuances:** AssemblyAI keyterms are capped (50 characters each, 100 items). Corrections apply to every final path: app, keyboard, import and History retry.

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
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android No
- **Excluded:** none
- **Gaps:** Android #1630.
- **How:** Apple platforms use CloudKit; Windows and Linux use CloudKit Web Services with the same record shape. A synced copy keeps its `originPlatform`; a local or imported record leaves it nil.
- **Refs:** `Sources/SpeakSync/HistoryChangeReconciler.swift`, `Sources/SpeakDesktopSync/DesktopHistorySyncStore.swift`, `Sources/SpeakDesktopHost/History/DesktopHostCloudSync.swift`, `Sources/SpeakApp/App/AppCloudSync.swift`, `Sources/SpeakWindows/WindowsCloudSync.swift`
- **Sunset:** iPhone has moved into the shared `iCloud.com.justspeaktoit` container with a one-time migration from the legacy iPhone container. After the #1119 device checks pass on Stable, drop the legacy entitlement entry, `SyncContainerFamily.iOS`, the migration, the deprecated `SyncConfiguration.legacyFamily` properties and the `IOS_SHARED_CLOUD_CONTAINER` variable ([shared container](cloudkit-shared-container.md)).
- **Nuances:** Never set `originPlatform` on migration imports: `removeSyncedCopy` may delete audio-free records that carry it. Mac/iPhone sync stays unqualified until the #1119 checks pass; the direct-download Mac build has no CloudKit entitlement yet ([Windows CloudKit sync](windows-cloudkit-sync.md)).

### F18 Settings search
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Every setting, card and page is an entry in `SettingsSearchCatalog` whose title equals the on-screen heading; hosts project it.
- **Refs:** `Sources/SpeakCore/SettingsSearch/SettingsSearchCatalog.swift`, `Sources/SpeakCore/SettingsSearch/DesktopSettingsSearch.swift`, `Sources/SpeakiOS/Views/Settings/IOSSettingsSearch.swift`, `android/app/src/main/java/com/justspeaktoit/android/settings/SettingsSearch.kt`
- **Sunset:** none
- **Nuances:** Coverage tests fail on unindexed settings (`Tests/SpeakAppTests/SettingsSearchCoverageTests.swift`). Regenerate `android/app/src/main/assets/settings_search.json` after changing Android entries ([settings search](settings-search.md)).

### F19 Command palette
- **Platforms:** macOS Yes · iOS N/A · Windows No · Linux No · Android N/A
- **Excluded:** iOS, Android (OS: no keyboard-first desktop shell; mobile uses settings search and system Shortcuts).
- **Gaps:** Windows, Linux #1619.
- **How:** One searchable palette over app commands and settings entries, opened by keyboard.
- **Refs:** `Sources/SpeakApp/Views/CommandPalette/CommandPaletteSearch.swift`, `Sources/SpeakApp/Views/Settings/SettingsSearchPalette.swift`, `Sources/SpeakCore/SettingsSearch/SettingsSearchCatalog.swift`
- **Sunset:** none
- **Nuances:** `Sources/CLinuxSupport/LinuxDesktopPalette.c` is a colour palette for theming, not a command palette.

### F20 Compare models
- **Platforms:** macOS Yes · iOS N/A · Windows Yes · Linux Yes · Android N/A
- **Excluded:** iOS, Android (owner decision: Compare models is desktop-only; #1622 closed as not planned).
- **Gaps:** none
- **How:** Run several models on the same audio, shown in a blind order the user ranks before names are revealed; saving results to History is opt-in.
- **Refs:** `Sources/SpeakDesktop/Comparison/DesktopComparisonRunner.swift`, `Sources/SpeakDesktopHost/Comparison/DesktopHostComparison.swift`, `Sources/SpeakApp/CompareModels/CompareModelsController.swift`, `Sources/SpeakWindows/WindowsComparison.swift`, `Sources/SpeakLinux/LinuxComparison.swift`
- **Sunset:** none
- **Nuances:** Comparisons are raw: no vocabulary seeding or automatic insertion. Don't add mobile UI for it.

### F21 Voice output / read aloud
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** Android #1631 (system TTS only; no provider or voice choice).
- **How:** Read a transcript or selection with the chosen provider and voice from the shared TTS catalogue; validate voice options before sending.
- **Refs:** `Sources/SpeakCore/TTS/Desktop/DesktopSpeechSynthesis.swift`, `Sources/SpeakDesktopHost/ReadAloud/DesktopHostReadAloud.swift`, `Sources/SpeakApp/TextToSpeech/TextToSpeechManager.swift`, `Sources/SpeakiOS/Services/VoiceOutputRouter.swift`, `android/app/src/main/java/com/justspeaktoit/android/ui/ReadAloudButton.kt`
- **Sunset:** OpenAI `/v1/audio/speech` TTS models shut down 2027-01-06 (`ModelRetirements`). ElevenLabs `elevenlabs/rachel|adam|bella` IDs migrate (`ElevenLabsTTSCatalog.legacyVoiceIdentifiers`). `SonioxTTSTextChunker` is a deprecated alias of `TTSTextChunker`, removed at the next major release.
- **Nuances:** Desktop SSML is capped at 64 KiB and never split. Groq PlayAI voices retired on 2025-12-31 and must not return (`Sources/SpeakCore/GroqTTSCatalog.swift`). Voice settings transfer atomically on desktop hosts ([desktop voice sources](desktop-voice-sources.md)).

### F22 Voice edit of selected text
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux No · Android No
- **Excluded:** none
- **Gaps:** Linux, Android #1620.
- **How:** Capture the selection and its target, dictate an instruction, rewrite with the cleanup model, then replace only in the captured target; never redirect to another field.
- **Refs:** `Sources/SpeakCore/PostProcessing/VoiceEditPolicy.swift`, `Sources/SpeakDesktop/Voice/DesktopVoiceEdit.swift`, `Sources/SpeakDesktopHost/Voice/DesktopHostVoiceEdit.swift`, `Sources/SpeakApp/VoiceEdit/VoiceEditController.swift`, `Sources/SpeakWindows/WindowsVoiceEdit.swift`
- **Sunset:** none
- **Nuances:** The Mac rejects missing or cross-process AX targets (`Sources/SpeakApp/Output/AccessibilityTextOutput.swift`).

### F23 Hands-free and silence auto-stop
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** Android #1632 (no hands-free voice-activity start with pre-roll; silence auto-stop only).
- **How:** Voice activity starts and stops capture; configured silence ends the session through the normal stop path.
- **Refs:** `Sources/SpeakCore/Capture/HandsFreeVoiceActivity.swift`, `Sources/SpeakCore/Capture/Apple/HandsFreeVoiceActivitySession.swift`, `Sources/SpeakDesktopHost/Recording/DesktopHostHandsFree.swift`, `Sources/SpeakApp/Session/HandsFreeDictationCoordinator.swift`, `Sources/SpeakiOS/Services/IOSHandsFreeDictationCoordinator.swift`, `android/app/src/main/java/com/justspeaktoit/android/dictation/SilenceAutoStop.kt`
- **Sunset:** none
- **Nuances:** iOS scene lifecycle rules: [iOS hands-free lifecycle](ios-hands-free-scene-lifecycle.md). Android ports `DictationSilenceMonitor` and the SpeakCore level scale for Cloud capture only, with the shared defaults (0.05 threshold, 2 s) and keys; its on-device and speech-service recognisers already end on a pause.

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
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android No
- **Excluded:** none
- **Gaps:** Android #1634.
- **How:** Check permissions, devices, keys and connectivity, explain each failure and link straight to its fix.
- **Refs:** `Sources/SpeakCore/Desktop/DesktopTroubleshooting.swift`, `Sources/SpeakCore/Troubleshooting/MobileTroubleshooting.swift`, `Sources/SpeakApp/Views/TroubleshootingView.swift`, `Sources/SpeakiOS/Views/Settings/IOSTroubleshootingView.swift`, `Sources/SpeakiOS/Views/CaptureHealthView.swift`, `Sources/SpeakWindows/WindowsTroubleshooting.swift`, `Sources/SpeakLinux/LinuxTroubleshooting.swift`
- **Sunset:** none
- **Nuances:** Re-read permission state after the user returns; a click is not proof of a grant. Phones use `MobileTroubleshooting` (microphone and speech permissions, on-device model, missing/rejected/unreadable keys, keyboard Full Access); a key is reported rejected only after Check key asks the provider. Capture Health stays the deeper capture self-test.

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
- **Platforms:** macOS Yes · iOS Yes · Windows No · Linux No · Android No
- **Excluded:** none
- **Gaps:** Windows, Linux, Android #1621.
- **How:** Read-only balance per provider that exposes one; show nothing for providers without a supported endpoint.
- **Refs:** `Sources/SpeakCore/Balance/ProviderBalance.swift`, `Sources/SpeakCore/Balance/ProviderBalanceDirectory.swift`, `Sources/SpeakCore/AppleUI/ProviderBalanceView.swift`
- **Sunset:** none
- **Nuances:** See [provider balances](provider-balances.md).

### F33 Configuration export/import and backup
- **Platforms:** macOS Yes · iOS Yes · Windows Partial · Linux Partial · Android No
- **Excluded:** none
- **Gaps:** Windows, Linux, Android #1635 (desktops back up History, and Windows profiles, only).
- **How:** Inspect an archive, stage it, then apply only valid categories; absent or damaged categories keep existing data. Secrets never travel.
- **Refs:** `Sources/SpeakCore/DataMigration/DataMigrationPlanner.swift`, `Sources/SpeakDesktop/Migration/DesktopMigrationArchive.swift`, `Sources/SpeakApp/DataMigration/MigrationPlanner.swift`, `Sources/SpeakiOS/Views/ConfigTransferView.swift`, `Sources/SpeakLinux/LinuxMigrationRestore.swift`
- **Sunset:** Legacy saved model references are rewritten on import (`Sources/SpeakApp/DataMigration/MigrationModelReferences.swift`).
- **Nuances:** Never turn a missing category into an empty replacement. See [configuration transfer](configuration-transfer.md) and [data migration](data-migration.md).

### F34 Raw settings editor and config tools
- **Platforms:** macOS Yes · iOS Partial · Windows Partial · Linux Partial · Android Partial
- **Excluded:** none
- **Gaps:** iOS, Windows, Linux, Android #1608 (Windows and Linux lack only the raw JSON editor window, #1670; iOS and Android have no automation server for the config tools).
- **How:** One JSON document of canonical keys with all-or-nothing validation, no secrets, and keys for other platforms preserved; the same document backs `speak config` and the MCP configuration tools.
- **Refs:** `Sources/SpeakCore/Automation/AutomationConfiguration.swift`, `Sources/SpeakCore/SettingsConfiguration/SettingsSchema+Desktop.swift`, `Sources/SpeakDesktopHost/Automation/DesktopHostAutomationConfiguration.swift`, `Sources/SpeakiOS/Views/Settings/IOSRawConfigurationEditorView.swift`, `android/app/src/main/java/com/justspeaktoit/android/settings/RawConfiguration.kt`, `Sources/SpeakApp/Views/Settings/RawConfigurationEditorView.swift`, `Sources/SpeakApp/Transport/AppAutomationHandler+Configuration.swift`
- **Sunset:** none
- **Nuances:** The desktop Preferences editor (`Sources/SpeakDesktopHost/Settings/DesktopHostConfigurationEditor.swift`) is a typed form, not this feature. The iPhone's Read aloud keys (#1671) share the Mac's `ttsSpeed`, `ttsLanguageIdentifier` and `sonioxTTSRegion` definitions (`SettingsSchema+VoiceOutput.swift`); its provider, model, voice and speed are checked together by `VoiceOutputProvider.selectionProblems`. They have no iPhone Settings page, so they are not in Settings search on iOS.

### F35 Automation (CLI, MCP, App Intents)
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Limited
- **Excluded:** none
- **Gaps:** none
- **How:** Off until the user enables it; the `speak` CLI and MCP talk to an app-owned Unix socket or named pipe and drive the normal dictation path. iOS uses App Intents and Shortcuts.
- **Refs:** `Sources/SpeakCore/Automation/AutomationCommandDispatch.swift`, `Sources/SpeakDesktopHost/Automation/DesktopHostAutomation.swift`, `Sources/SpeakApp/Transport/AutomationServer.swift`, `Sources/SpeakCLI`, `android/app/src/main/java/com/justspeaktoit/android/surfaces/DictateTileService.kt`
- **Sunset:** none
- **Nuances:** Android has the tile and launcher shortcut only, with no CLI by design. See [automation](automation.md).

### F36 Usage insights dashboard
- **Platforms:** macOS Yes · iOS No · Windows Yes · Linux Yes · Android Partial
- **Excluded:** none
- **Gaps:** iOS, Android #1623 (Android: 7-day dictations and words card only).
- **How:** Derive totals and trends from completed History entries on the device.
- **Refs:** `Sources/SpeakCore/SpeechInsights/SpeechInsightsEngine.swift`, `Sources/SpeakDesktop/History/DesktopHistoryPresentation.swift`, `Sources/SpeakApp/Views/Dashboard/SpeechInsightsDashboard.swift`, `android/app/src/main/java/com/justspeaktoit/android/history/HistoryInsights.kt`
- **Sunset:** none
- **Nuances:** Count only completed entries with text, as `HistoryInsights` does.

### F37 Opt-in analytics and crash reporting
- **Platforms:** macOS Yes · iOS Yes · Windows No · Linux No · Android Yes
- **Excluded:** none
- **Gaps:** Windows, Linux #1624.
- **How:** Nothing is sent until the user opts in; crash events are scrubbed before upload. Withdrawing consent drops queued analytics events (cancelling one in flight) and deletes queued crash reports without sending them.
- **Refs:** `Sources/SpeakApp/Analytics/AnalyticsLocalPolicy.swift`, `Sources/SpeakApp/Analytics/PostHogAnalytics.swift`, `Sources/SpeakApp/Analytics/SentryManager.swift`, `Sources/SpeakApp/Analytics/SentryEventScrubber.swift`, `android/app/src/main/java/com/justspeaktoit/android/telemetry/ProductAnalytics.kt`, `android/app/src/main/java/com/justspeaktoit/android/telemetry/SentryCrashReporter.kt`
- **Sunset:** none
- **Nuances:** Sentry is EU-hosted; PostHog covers product events only ([analytics plan](analytics-plan.md), [PostHog maintenance](posthog-maintenance.md)).

### F38 Tip jar / paid access
- **Platforms:** macOS Yes · iOS Yes · Windows No · Linux No · Android Partial
- **Excluded:** none
- **Gaps:** Windows, Linux, Android #1625 (Android: tip jar only, no paid access).
- **How:** The tip jar uses StoreKit, and Google Play Billing consumables with the same product IDs on Android. Paid access proxies requests through a Cloudflare Worker (`workers/paid-access`) that holds vendor keys, so subscribers need no API keys; it is entitlement-checked at routing time.
- **Refs:** `Sources/SpeakApp/App/TipStore.swift`, `Sources/SpeakApp/Views/TipJarView.swift`, `Sources/SpeakApp/PaidAccess/PaidAccessManager.swift`, `workers/paid-access`, `android/app/src/main/java/com/justspeaktoit/android/tips/PlayBillingTipStore.kt`
- **Sunset:** Paid access stays compiled dark (`TUIST_PAID_ACCESS`) until the owner launches it ([paid access](paid-access.md)).
- **Nuances:** Use `@ObservedObject` for `TipStore.shared`, never `@StateObject`. Stale preferences can't enable paid access in a public build. Android thanks the user only after Play confirms the consume, and retries a failed one so the tier can be bought again and isn't refunded.

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
- **Platforms:** macOS Yes · iOS Partial · Windows Yes · Linux Yes · Android No
- **Excluded:** none
- **Gaps:** iOS, Android #1637 (iOS follows the system route).
- **How:** The chosen device applies when the next input session begins; otherwise the OS default is used. Label it as a preference, not the measured route (#852).
- **Refs:** `Sources/SpeakApp/Audio/AudioInputDeviceManager.swift`, `Sources/SpeakWindows/WindowsMicrophones.swift`, `Sources/SpeakLinux/LinuxMicrophoneMonitor.swift`
- **Sunset:** none
- **Nuances:** See [Windows microphone discovery](windows-microphone-discovery.md).

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
- **Platforms:** macOS Yes · iOS Partial · Windows No · Linux No · Android No
- **Excluded:** none
- **Gaps:** iOS, Windows, Linux, Android #1640.
- **How:** The Mac runs a user-enabled, paired, encrypted WebSocket receiver (`SpeakTransportWire` v2 over Bonjour) that inserts at the cursor. A phone sender must use the same protocol.
- **Refs:** `Sources/SpeakCore/Sync/Apple/TransportChannel.swift`, `Sources/SpeakApp/Transport/TransportServer.swift`, `Sources/SpeakApp/Transport/SendToMacAvailability.swift`, `Sources/SpeakiOS/Services/TranscriptHandoffPublisher.swift`, `Docs/MACOS_RECEIVER.md`
- **Sunset:** none
- **Nuances:** iPhone has no direct sender: it reaches the Mac through Handoff ("Continue on Mac") and History sync. v1 plaintext peers are refused. The receiver ships only in the direct macOS build: the Mac App Store build has no `network.server` entitlement or Bonjour service and hides Send to Mac (`SendToMacAvailability`).

### F47 Accessible names, IDs and recording announcements
- **Platforms:** macOS Yes · iOS Yes · Windows Yes · Linux Yes · Android Yes
- **Excluded:** none
- **Gaps:** none
- **How:** Every control has a name, role, state and stable automation ID; recording start, stop and errors are announced.
- **Refs:** `scripts/accessibility/check-apple-accessibility.py`, `scripts/accessibility/check-linux-accessibility.py`, `android/app/src/main/java/com/justspeaktoit/android/ui/AutomationIds.kt`, `Docs/accessibility.md`
- **Sunset:** none
- **Nuances:** `make lint` enforces the Apple rules; suppress only with `// a11y-ignore: reason`. Owner passes are tracked in #1399.

### F48 Learned auto-corrections
- **Platforms:** macOS Yes · iOS No · Windows Yes · Linux Yes · Android Limited
- **Excluded:** none
- **Gaps:** iOS #1651.
- **How:** Watch the field after inserting; when the same edit recurs it is promoted to a correction rule (F12). Platforms supply only field monitoring.
- **Refs:** `Sources/SpeakCore/Vocabulary/Apple/AutoCorrectionEngine.swift`, `Sources/SpeakApp/PostProcessing/AutoCorrectionTracker.swift`, `Sources/SpeakDesktopHost/Controller/DesktopHostController.swift`, `Sources/SpeakApp/PostProcessing/PersonalCorrectionsView.swift`, `android/app/src/main/java/com/justspeaktoit/android/corrections/AutoCorrectionLearning.kt`, `android/app/src/main/java/com/justspeaktoit/android/ime/KeyboardCorrectionObserver.kt`
- **Sunset:** none
- **Nuances:** iOS automatic polish is cleanup, not learned correction. Desktops share `DesktopHostCorrectionLearning`. Android mirrors `WordDiffer` and the learning policy in Kotlin (`WordDifferParityTest` pins shared cases; change both together). Its keyboard reads only the field it typed into, while it is still in that field, between the text remembered either side of the insertion; switching to another keyboard ends the watch. Password, no-suggestion and no-personalised-learning fields are never read. Promoted edits join Personal corrections; dismissed suggestions stay hidden.

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
- **How:** iOS: the keyboard hands off to the app to record, then inserts the result on return. Android: an IME records and commits into the focused field.
- **Refs:** `Sources/SpeakCore/Keyboard/Apple/KeyboardHandoff.swift`, `Docs/ios-keyboard-v2-design.md`, `android/app/src/main/java/com/justspeaktoit/android/ime/DictationKeyboardService.kt`, `Docs/android-input-surfaces.md`
- **Sunset:** `TUIST_IOS_KEYBOARD_DIRECT_CAPTURE` is an experiment (#661); Apple gives custom keyboards no microphone. `KeyboardHandoff.legacyRecordKey` (v3) is still read for migration.
- **Nuances:** The iOS app runs on iPad: name the device through `DeviceCopy`, never "iPhone" (`Sources/SpeakiOS/Views/DeviceCopy.swift`).

## Companion surfaces

### W01 watchOS companion
Starts and stops capture on the watch, queues recordings for transfer to the
iPhone and shows state in a complication. Gated by `TUIST_WATCH_APP` (Alpha
only) until the owner approves it for Stable. Refs:
`Sources/SpeakWatchCore/WatchRecordingLifecycle.swift`,
`Sources/SpeakWatchCore/WatchCaptureProtocol.swift`, [watch provisioning](watch-provisioning.md).
It uses its own App Group (`group.com.justspeaktoit.watch`); without it,
storage falls back to Application Support and the complication shows idle.
