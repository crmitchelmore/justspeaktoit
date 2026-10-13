# Desktop settings coverage

This is a settings slice, **not full Windows/Linux feature parity**. Baseline:
macOS `AppSettings.DefaultsKey` has 91 keys
(`Sources/SpeakApp/AppSettings.swift:289-381`), plus preferences and collections
outside that enum. Track remaining product acceptance in #1157.

## Generated-speech coordination

`SpeechGenerationDefaults` defines the Mac's existing `ttsAutoPlay` (true) and
`ttsSaveToDirectory` (false) defaults without changing saved values. Explicit
Read aloud is independent from auto-play. The Voice workflow owner implements
immutable Generate snapshots, retained results, cached Play/export and native
controls; the shared model must be the sole persisted desktop boolean authority,
not an independent copy in each platform or in the configuration dictionary.
Canonical portable transfer now projects those two flags into the shared
`DesktopVoiceOutputSettings` model in one atomic settings write. Import validates
strict booleans, preserves voice/model IDs and absent flags, and removes the
transferred flags from the dictation configuration dictionary. Export derives
them from that model, not a second persisted authority. Shared transfer-only
metadata does not add duplicate Voice switches to the dictation editor. Native
voice selection preserves both flags.
This is **transfer support, not executable Voice acceptance**: Generate,
retained results and the native Voice controls remain in #1217.
Voice flags do not increase this slice's editable preference count. There are fourteen
previously accepted preferences plus three recording-sound preferences now wired
below; native sound acceptance is still pending.

Generated audio archival follows the parent's app-owned destination: the actual
`DesktopRecordingStore.directory`, as a flat canonical `UUID.wav` without a
transcript journal entry. This participates in the parent's audio-only cleanup;
separate generated-result cache/playback staging does not. Foreign imported
`recordingsDirectory` values are never executed. UUID filenames replace the
Mac's colon-containing timestamps on Windows. Native archival and Voice
acceptance belong to the Voice/parent workstreams, not this defaults extraction.

## Recording feedback (native acceptance pending)

`SpeakCore/RecordingFeedback.swift` now owns the four existing profiles, eight
M4A names, enabled/classic/0.7 defaults and the Mac player's volume-squared curve.
The Apple player keeps its nested API names as aliases to this catalogue and
still reads its established main-bundle resources. `SpeakFeedbackResources`
owns the existing root `Resources/Sounds` directory with `.copy("Sounds")`;
Windows/Linux platform targets depend on it without copying or changing assets.
Its resolver refuses links, non-regular files and empty or over-1-MB assets.
Resource tests assert all eight names and M4A headers in the actual SwiftPM
bundle; a Windows production-collector test asserts all eight byte-exact files.
Linux production staging also needs the sibling-resource collector in #1212.

`SpeakDesktop/DesktopRecordingFeedback.swift` provides isolated feedback output
ownership, cancellable preparation, reserved recording IDs, capture-ready/normal
finish cues, duplicate/stale rejection, explicit disabled previews, volume-only
reuse and awaited cleanup. Fake-output lifecycle tests do **not** prove native
decoding, sound output or warm-path latency. Dedicated Windows WASAPI/Media Foundation and Linux
libpulse/GStreamer outputs now preload both cues off the controller and retain
an independently owned native channel. Warm play does not reopen assets or
decode audio. Read aloud and History output are not reused or stopped.

The shared host reserves feedback before suspended capture startup, plays Start
only after capture starts and Stop only after the owned tail/capture stops
normally, including an empty recording. Failed startup, capture errors,
cancellation and shutdown do not play Stop. Preparation/play/device/cleanup
errors are explicitly reported without failing dictation. Shutdown independently
waits for feedback within its existing five-second aggregate grace period.

General now exposes the Mac's `recordingSoundsEnabled`, `recordingSoundProfile`
and `recordingSoundVolume` with canonical defaults and strict validation.
Save-and-preview actions persist all current fields atomically and run native
preparation independently of the settings queue. Explicit previews work while
automatic sounds are disabled and cannot replay after an intervening recording.
Volume edits while enabled reuse the channel; profile edits retire it without affecting other
audio. Native tests and executable self-tests require production decoding of all
eight assets; Linux additionally exercises the warmed channel on its private
PipeWire sink with a 100 ms first-buffer admission bound. This measures native
queue admission, **not audible hardware latency**.

These three preferences are **wired, awaiting native acceptance**. Actual
Windows x64 and ARM64 builds and all eight AAC decodes passed at `cf4779d1`.
Its Windows developer bundle also decoded all eight production assets on the
local host; the real default endpoint admitted both cues in every profile in
2.394-6.934 ms and passed reusable stop/joined close. That local run used the
existing installed Swift runtime, not a newly installed self-contained bundle.
The CI MSIX bundle/native self-tests passed, but the lifecycle readiness probe
rejected the nonfatal no-audio-device warning. The bounded actionable warning
retains the full error in stderr and does not disable capture.
Linux built and decoded all eight AACs, then failed a test fixture constructed
at unsupported 8 kHz before reaching its intended decoded-duration check; the
fixture now uses supported 16 kHz, with endpoint/package qualification pending
the rerun. Final-head native controls, Linux endpoint and installed-package
resource/codec evidence remain required before calling the sound journey
accepted. Linux deployment composes the sibling collector in
#1212 and needs AAC decoding (Ubuntu: `gstreamer1.0-libav`).

## Implemented preference journey

Windows uses **Dictation preferences...** from General, Transcription,
Post-processing and Keyboard. Linux uses native libadwaita preference groups
in those same destinations. Fields are defined once in
`Sources/SpeakCore/DesktopConfiguration.swift`; native controls receive that
schema rather than maintaining copies of defaults. Scalar defaults now use
`SpeechDefaults` in the shared schema and canonical Mac `AppSettings` initializer;
an Apple test compares all fourteen preferences to a fresh Mac settings store.
Keyword reconciliation also maintains two migration/recovery metadata keys;
these are not two additional independent preference switches.
All fields are validated
before one atomic settings write; a failed write leaves the controller unchanged.
Changes apply to subsequent recordings. Spoken-language profile overrides still
win, including an explicit Automatic overriding a global language selection.
Imports capture the language and retries keep the original recording's language.

Language accepts Automatic or a provider locale, including existing custom locale
identifiers not listed in the shared catalogue. Model capability gates still
apply. Keyword bias is currently wired to xAI dedicated STT streaming; AssemblyAI
projects the same shared list into its keyterms option. Stop grace is wired to AssemblyAI and
Cartesia. Other live routes and batch providers do **not** gain keyword/grace
support merely because these fields exist. Additional provider wiring belongs
in the canonical streaming factory, not a platform-specific list.

The keyword and legacy AssemblyAI fields are mirrors of one shared list, as on
Mac. `TranscriptionKeywordPolicy` is the canonical pure reconciliation policy
used by both Mac and desktop stores. Initial competing nonempty lists are merged;
after reconciliation, an unchanged mirror cannot override a deliberate edit or
clear. Independent clear/edit conflicts keep the clear active and retain the
other edit for explicit recovery. Native Transcription preferences offer a
recovered-edit picker and Restore action; it adds only the selected words to the
current list, removes only that recovery item and writes atomically. Recovery
carries the selected text, not a stale row index, and refuses an edit that no
longer exists. Recovery metadata is validated (up to 1000 lists, 65535 UTF-8
bytes per text); merged active lists must also fit the existing field bound.
Relaunch, Apply and configuration transfer preserve clears and pending recovery.
Native editor validation checks scalar bounds without inventing merge history;
the controller reconciles against the actual saved mirror before persistence.
This does not implement lexicon matching or expand provider support.

Temperature and output language reach OpenRouter cleanup, and changing its
enabled/model/prompt controls no longer resets those advanced preferences.
Shortened error display uses the Mac's 3.6-second failure interval instead of
6 seconds, forwarded to the actual Windows and X11 native HUD hide timers.
Wayland preserves its non-activating desktop notification replacement; the
desktop notification server, not the app, controls notification expiration.
Compact HUD matches the Mac's small dot/level-meter/whole-second-clock layout,
with one trailing transcript line and terminal status instead of the full card.
It preserves session clocks, visibility/retraction policy and terminal timers.
The default remains the full card. Its native size chooser uses the canonical
Compact / Always Expanded / Auto-Expand identifiers and policy shared with Mac.
Auto-Expand triggers strictly after 100 visible transcript characters and remains
expanded through retractions and later phases until the next recording. Expanded
Windows/X11 cards are wider and show up to six transcript lines; the minimal
`showCompactHUD` presentation still takes precedence. Hidden live previews cannot
trigger automatic expansion. Size changes preserve the phase clock and never
activate the HUD. The existing desktop latest-280-character projection remains
bounded; this is not the Mac's full transcript-scrolling journey. On Wayland, overlay-only rows are hidden with
an explanation; their values are retained when applying or transferring preferences.
The shared field schema marks these capabilities rather than duplicating labels
or catalogue entries in the native UI. Native capture-health footer details and
the Mac's interactive expansion chevron remain separate gaps.
Cleanup remains opt-in; changing preferences does not enable it. HUD visibility
and live-preview visibility gate the real native HUD. Shortcut timing reaches
the existing shared gesture machine on both platforms, not fixed platform timers.

The Recording buffer keeps native capture and live PCM delivery running for
0...2 seconds after a finish request (Mac default: 0.5 seconds), before closing
the WAV and starting transcription/finalisation. Duplicate finish requests
cannot create another buffer. Cancel ends it immediately and retains the audio
without transcription or insertion; capture failure and shutdown take the
capture away before cancelling the timer, so a stale stop cannot touch a new
recording. Provider stop grace begins after this capture buffer, not instead of it.

Linux clipboard restoration is **partial**, not an equivalent all-format backup.
X11 restores previous plain text only while the exact owned selection remains:
native receipts, provider identity and a server-side selection-owner transaction
prevent overwriting a later copy, including identical text or another output run.
Cancellation stops delayed restoration, and read/restore failures are reported.
Wayland's portal cannot acknowledge paste consumption, so it never reads or
restores previous contents after guessed delays. General hides the unsupported
restore switch, explains why pasted text remains on the clipboard and retains
the saved X11 choice; dashboard/save messages follow the actual session capability,
including Wayland sessions with an XWayland `DISPLAY`. Windows behavior is unchanged.
The explanation belongs to the visible Output group description, not the
combobox's non-rendered subtitle. The isolated screenshot tour seeds actual session
options and also captures the explicit `general-portal-output` capability fixture;
it restores the original output options before subsequent stages.

## Configuration transfer is not the Mac backup format

General's Import/Export preferences actions use a bounded, versioned JSON object:

```json
{"version":1,"preferences":{"preferredLocale":"en_GB","holdThreshold":0.35}}
```

Both transfers enforce a 1 MB limit. An oversized export is refused before
replacing its destination, rather than producing a file the importer cannot read.

This transfers the portable preferences above and projects the two supported
generated-speech flags when a Voice model has been saved. A legacy document with
no flags leaves the existing Voice options unchanged. Hosts without the executable
Voice contract preserve those keys without applying them. Other Voice options,
including speed/pitch/SSML, remain opaque until a real provider can execute them.
It does not read credential stores
or transfer native model selections, hotkey codes, microphone IDs, device paths,
startup registration or automation permission. Imported unknown/unsupported
entries are retained exactly across edits/exports and named as **preserved but
not applied**. Imported opaque values can themselves contain private data:
inspect a file before sharing it. Unknown root entries already present in the
desktop settings file also survive writes to other settings.

This JSON is **not** the macOS Data & Migration ZIP. Mac backups use
`manifest.json`, category records (`id`, `kind`, `value`), vocabulary/models/
profiles/history/connections/credentials and optional audio
(`Sources/SpeakApp/DataMigration/MigrationArchive.swift:7-59`,
`MigrationCatalog.swift:13-77`, `MigrationPreferenceSchema.swift:6-70`).
Importing that archive, mapping its categories safely, merge/replace previews,
rollback and exporting a Mac-compatible archive remain gaps. No ZIP is
misidentified or silently imported as portable preferences.

## Evidence legend

The table is exhaustive for the 91 enum keys. "Equivalent" denotes a working
native replacement, not identical Apple APIs or identifiers; "Partial" is not
parity. Evidence labels refer to executable surfaces:

| Label | Files |
|---|---|
| Config | `SpeakCore/DesktopConfiguration.swift`, `SpeakDesktopHost/DesktopHostConfiguration.swift`, `SpeakWindows/WindowsConfiguration.swift`, `SpeakLinux/LinuxConfiguration.swift` (all under `Sources`) |
| Models | `Sources/SpeakDesktopHost/DesktopHostModels.swift`, `DesktopHostModelDiscovery.swift`, `DesktopHostLocalModels.swift`, `SpeakDesktop/DesktopLiveTranscription.swift` |
| Output | `Sources/SpeakWindows/WindowsTextOutputSettings.swift`, `SpeakLinux/LinuxControllerSettings.swift`, `SpeakLinuxPlatform/LinuxTextOutput.swift` |
| HUD | `Sources/SpeakDesktopHost/DesktopHostHUD.swift`, `Sources/SpeakDesktop/DesktopHUD.swift` |
| Keys | `Sources/SpeakDesktopHost/DesktopHostCredentials.swift`, `SpeakWindows/WindowsNative.swift`, `SpeakLinuxPlatform/LinuxCredentialStore.swift` |
| Shortcuts | `Sources/SpeakWindows/WindowsHotKey.swift`, `Sources/SpeakLinux/LinuxShortcutGestures.swift`, `SpeakCore/HotKeyGestureMachine.swift` |
| Voice | `Sources/SpeakDesktopHost/DesktopHostReadAloud.swift`, `SpeakWindows/WindowsReadAloud.swift`, `SpeakLinux/LinuxReadAloud.swift` |
| General | `Sources/SpeakDesktopHost/DesktopHostSettings.swift`, `DesktopHostLoginItem.swift`, `SpeakWindows/WindowsLoginItemHost.swift`, `SpeakLinux/LinuxLoginItemHost.swift` |
| Automation | `Sources/SpeakWindows/WindowsAutomation.swift`; Linux currently has `--toggle`, not the Mac automation server |

Paths named relative to `Sources` in a cell inherit the preceding `Sources/`
prefix. Missing rows cite the canonical Mac definition above and their native
replacement/nearest implemented surface; they do not assert hidden support.

| Mac key | Windows / Linux outcome | Evidence or remaining work |
|---|---|---|
| appearance | Equivalent / Equivalent | General; system/light/dark native schemes |
| visualDensity | Missing / Missing | Fixed native layout, no density editor |
| transcriptionMode | Equivalent / Equivalent | Models; Remote Batch/Live and Local batch |
| liveTranscriptionModel | Partial / Partial | Models; implemented transport routes only; Apple Speech and unavailable providers are not substitutes |
| batchTranscriptionModel | Equivalent / Equivalent | Models; independent remembered batch model |
| localTranscriptionModel | Partial / Partial | Models; whisper.cpp catalogue, not all Mac inference runtimes/imports |
| localTranscriptionMode | Partial / Partial | Local batch only; local streaming absent |
| localStreamingModelSource | Missing / Missing | No native local streaming source editor/runtime |
| postProcessingEnabled | Equivalent / Equivalent | `DesktopHostPostProcessing.swift`; remote opt-in differs deliberately from Mac's default-on |
| postProcessingModel | Partial / Partial | Shared remote catalogue; local LLM/rules cleanup unavailable |
| postProcessingTemperature | Wired / Wired | Config; range 0...1, OpenRouter request |
| postProcessingOutputLanguage | Wired / Wired | Config; cleanup system prompt |
| postProcessingIncludeLexiconDirectives | Missing / Missing | No desktop lexicon pipeline in this baseline |
| postProcessingIncludeContextTags | Missing / Missing | No desktop lexicon context pipeline |
| textOutputMethod | Equivalent / Partial | Output; Windows Smart/direct/clipboard; Linux paste/clipboard, no direct accessibility insertion |
| restoreClipboard | Equivalent / Partial | Output; Windows restoration; Linux X11 owned plain-text restoration only. Wayland capability-gates the control, retains its saved X11 choice and leaves pasted text on the clipboard |
| appSwitchDelivery | Missing / Missing | Windows captured-target safety; Linux X11 captured/Wayland current-focus rules, no three-way selector |
| showHUD | Wired / Wired | Config + HUD |
| appVisibility | Missing / Missing | Native window/tray behaviour; no Mac Dock/menu-bar mode selector |
| showStatusBarIconInDockOnly | Apple-specific / Apple-specific | Dock-only is not a native Windows/Linux mode; tray equivalents need explicit product policy |
| compactStatusBarIcon | Missing / Missing | No tray compact-style preference |
| runAtLogin | Equivalent / Equivalent | General; native startup task/login entry, OS status displayed |
| recordingsDirectory | Missing / Missing | Fixed private per-user History directory, no relocation UI |
| hotKeyActivation | Equivalent / Equivalent | Shortcuts; press/hold/double-tap/combined styles; Linux portal availability caveat |
| holdThreshold | Wired / Wired | Config + shared gesture machine; 0.2...1.5 s |
| doubleTapWindow | Wired / Wired | Config + shared gesture machine; 0.2...1 s |
| trackedKeyIdentifiers | Equivalent / Equivalent | Keys; provider credential names, not values; no full API-key management destination |
| preferredLocale | Wired / Wired | Config + `DesktopProfileSession.swift`; provider language capability gates; automation language remains a separate gap |
| postRecordingTailDuration | Wired / Wired | Config + `DesktopHostRecordingTail.swift`; owned 0...2 s capture buffer, immediate cancel/failure/shutdown cleanup, no stale finalisation |
| deepgramStopGracePeriod | Missing legacy migration / Missing legacy migration | Portable JSON preserves this obsolete key but does not reinterpret it as new grace |
| liveStopGracePeriod | Partial / Partial | Config; AssemblyAI/Cartesia only; range 0...2 s |
| preferredAudioInputUID | Equivalent / Equivalent | Native device ID with missing-device warning, never Apple UID translation |
| defaultTTSVoice | Partial / Partial | Voice; canonical Deepgram Read aloud voices only |
| ttsLanguage | Missing / Missing | No independent TTS-language editor |
| sonioxTTSRegion | Missing / Missing | Soniox TTS route unavailable |
| ttsSpeed | Missing / Missing | No speech-rate editor |
| ttsPitch | Missing / Missing | No pitch editor |
| ttsQuality | Missing / Missing | No quality editor/provider options |
| ttsOutputFormat | Missing / Missing | Read aloud uses native staging format |
| ttsAutoPlay | Transfer wired; workflow pending / Same | Strict canonical boolean projects to the sole Voice model; explicit Read aloud remains playback; Generate acceptance belongs to #1217 |
| ttsSaveToDirectory | Transfer wired; workflow pending / Same | Strict boolean projects to sole Voice model; generated WAV archival uses actual owned recordings directory in #1217, never an imported foreign path |
| ttsUseSSML | Missing / Missing | No SSML input/editor/provider contract |
| ttsFavoriteVoices | Missing / Missing | No voice favourites |
| ttsPronunciationDictionary | Missing / Missing | No TTS pronunciation editor/pipeline |
| historyFlushInterval | Missing selector / Missing selector | History is durable per operation, not configurable timed flush |
| silenceDetectionEnabled | Missing / Missing | No configured silence stop pipeline |
| handsFreeDictationEnabled | Missing / Missing | No hands-free session loop in this baseline |
| silenceThreshold | Missing / Missing | No silence threshold editor/pipeline |
| silenceDuration | Missing / Missing | No silence duration editor/pipeline |
| connectionPreWarmingEnabled | Missing / Missing | No persistent provider prewarming preference |
| audioPreWarmingEnabled | Missing / Missing | Native capture opened on demand, no capture prewarming preference |
| warmMicrophoneOnKeyPress | Missing / Missing | No speculative microphone-open preference |
| postProcessingStreamingEnabled | Missing / Missing | Finished-text remote cleanup only |
| hudSizePreference | Wired / Partial | Config + shared `HUDExpansionPreference`; native chooser and full-card expansion on Windows/X11; retained but hidden on Wayland |
| showLiveTranscriptInHUD | Wired / Partial | Config + Windows/X11 HUD; Wayland has no live overlay, so the control is hidden; transcript remains in main window |
| showCompactHUD | Wired / Partial | Config + native compact Windows/X11 renderer; hidden on Wayland, where notifications are compositor-owned |
| shortenErrorDisplay | Wired / Partial | Config + HUD; native Windows/X11 timer; Wayland notification lifetime is desktop-owned |
| showSidebarShortcutHints | Missing / Missing | Native sidebar has no hint visibility preference |
| speedMode | Missing / Missing | No Instant/Live Polish setting; no live-polish engine |
| livePolishModel | Missing / Missing | No live-polish model execution |
| livePolishDebounceMs | Missing / Missing | No live-polish scheduler |
| livePolishMinDeltaChars | Missing / Missing | No live-polish delta threshold |
| livePolishTailWindowChars | Missing / Missing | No live-polish tail rewriting |
| skipPostProcessingWithLivePolish | Missing / Missing | No live-polish pipeline |
| voiceCommandsEnabled | Missing / Missing | No voice-command processing |
| streamingInsertionEnabled | Missing / Missing | Final transcript insertion only |
| clipboardInsertionTriggers | Missing / Missing | No keyword-controlled clipboard insertion |
| enableSendToMac | Partial / Partial | iCloud web History sync is not Send-to-Mac transport/pairing |
| enableAutomationServer | Equivalent / Missing | Automation; Windows per-user named pipe, Linux toggle only |
| pasteRemoteTranscriptsAtCursor | Missing / Missing | No remote transcript delivery preference |
| autoCorrectionsEnabled | Missing / Missing | No correction capture/promotion/preview pipeline in baseline |
| autoCorrectionsPromotionThreshold | Missing / Missing | No correction promotion policy/editor |
| recordingSoundsEnabled | Wired, unverified / Wired, unverified | General + owned native channel; normal readiness/finish cues only; exact-head native acceptance pending |
| recordingSoundProfile | Wired, unverified / Wired, unverified | Canonical four profiles + owned preload replacement and explicit previews; codec acceptance pending |
| recordingSoundVolume | Wired, unverified / Wired, unverified | Strict 0...1 field + Mac volume-squared gain; native/installed-package acceptance pending |
| assemblyAIKeyterms | Wired / Wired | Config + options-bearing live factory; provider enforces vocabulary bounds |
| transcriptionKeywords | Partial / Partial | Config; xAI STT live only here, other provider/batch forwarding remains |
| transcriptionKeywordsLastReconciled | Wired / Wired | Shared `TranscriptionKeywordPolicy` + Config; unchanged-mirror/deliberate-clear reconciliation, durable last mirror |
| recoveredTranscriptionKeywords | Wired / Wired | Config; native selected-edit recovery with stale-selection and atomic-write guards |
| assemblyAIIgnoredPronunciationTerms | Missing / Missing | No pronunciation keyword-suppression editor |
| modulateSpeakerDiarization | Missing / Missing | Modulate live route/options not admitted by baseline desktop factory |
| modulateEmotionSignal | Missing / Missing | Same provider qualification gap |
| modulateAccentSignal | Missing / Missing | Same provider qualification gap |
| modulatePIIPhiTagging | Missing / Missing | Same provider qualification gap |
| accessibilityInsertionMode | Equivalent / Missing | Output; Windows cursor/replace-field; Linux paste cannot claim AX replace-all equivalence |
| selectedHotKey | Equivalent / Partial | Shortcuts; Windows Ctrl/Alt native key; Linux desktop/portal-owned binding, never Mac Fn key translation |
| paidAccessRoutingEnabled | Missing / Missing | BYOK desktop providers; no paid-access entitlement/routing journey |
| simpleModelChoices | Missing / Missing | Native catalogue picker without simplified paid-model chooser |
| rememberedLocalTranscriptionSource | Partial / Partial | Models remembers Local selection; no Apple on-device source |
| rememberedRemoteTranscriptionMode | Equivalent / Equivalent | Models; native source/mode preferences |
| analyticsEnabled | Missing / Missing | No native analytics consent/pipeline; do not treat missing as enabled |

## Beyond the enum and destinations

`postProcessingSystemPrompt` is represented by the existing native custom prompt
and reaches the shared cleanup policy. `customShortcutBindings`/individual action
shortcuts, Shortcut presets/reset, Escape cancellation and conflict management
beyond the global key remain gaps. Profiles have a Windows native editor with
shared ordering/session snapshots; Linux lacks a profile editor, even though
the host can load shared profiles. Apple bundle-ID matchers are preserved but
not silently converted to executable paths.

The Mac's 12 `SettingsTab` destinations are General, Transcription,
Post-processing, Profiles, Voice Output, Pronunciation, API Keys, Keyboard,
Permissions, Compare Models, Data & Migration and About
(`Sources/SpeakApp/Views/Settings/SettingsTab.swift:3-15`). Native desktops expose
General/Transcription/Post-processing/Voice Output/Keyboard/About and iCloud sync;
Windows also exposes Profiles. Provider keys are embedded under Transcription,
not a complete API Keys management page. Pronunciation, permission
troubleshooting/remediation, comparison, full archive migration and Linux
profile editing remain missing journeys. Corrections and Troubleshooting
destinations outside `SettingsTab` likewise remain unimplemented. No placeholder
destination or inert switch is added for those gaps.

Local model discovery/import/preparation, lexicon/corrections/pronunciation,
TTS usage/history, audio-only housekeeping/text-file import, profile archive merge, paid access,
diagnostics, automation and hands-free work need their own qualified native
engine journeys. Apple Speech, WhisperKit, FluidAudio, MLX, Dock/Fn, Keychain,
CloudKit native and App Store/StoreKit capabilities need explicit native
replacements, not engine-ID renaming.

Mac does not expose an automatic History/audio retention limit. Its General
Housekeeping actions reveal the recordings directory and delete recordings
without deleting History metadata, including orphan audio kept by earlier row
deletions (`Sources/SpeakApp/Views/Settings/SettingsView+General.swift:578-614`).
Those distinct actions and recording-directory configuration belong to the
parent History workstream; an invented expiry policy is not a parity requirement.

Portable tests: `Tests/SpeakDesktopTests/DesktopConfigurationTests.swift` and
`Tests/SpeakDesktopHostTests/DesktopHostConfigurationTests.swift`. Native smoke
tests include Windows field validation/apply/cancel and Linux schema population.
HUD assertions cover standard/short error durations, replacement errors,
obsolete hide callbacks during recording and timer cleanup at shutdown, plus
compact layout, clock continuity, whole seconds, transcript visibility and focus.
X11/Wayland configuration smoke checks verify capability-filtered row visibility;
all stored values still participate in Apply. Screenshot tours include full and
compact recording/completion cards.
These synthetic checks do not establish physical microphone/shortcut/display
acceptance, provider accuracy or macOS feature parity.
