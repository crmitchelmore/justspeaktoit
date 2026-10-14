# Desktop settings coverage

This is a settings slice, **not full Windows/Linux feature parity**. Baseline:
macOS `AppSettings.DefaultsKey` aliases the shared 91-key
`ApplicationPreferenceKey` (`Sources/SpeakCore/ApplicationPreferenceKey.swift`),
plus preferences and collections
outside that enum. Track remaining product acceptance in #1157.

## Local canonical archive projection candidate

This bounded bridge is a **read-only partial projection**, not a full backup,
import transaction, native control change or declaration of 91 executable
preferences. It is locally composed with the explicitly selected integration
base `78ad44e849cffdb986c25948de2c286c8f42ff80`; its qualification must not borrow
the earlier native or Apple receipts below. Publication requires parent review.

The parent collector can call
`DesktopHostController.preferenceArchiveProjection(categories:validateJSON:)`
inside the host, or
`DesktopHostPreferenceArchive.project(_:categories:validateJSON:)` on an
immutable `Settings` snapshot. The result is
`DataMigrationPreferenceProjection`, containing category-keyed canonical
`DataMigrationRecord` arrays and typed, value-free notices. Only explicitly
selected `.settings`, `.vocabulary` and `.connections` are accepted; any
credentials/collection category is rejected. Empty selected categories are
returned as empty arrays, not as a guarantee that every store was collected.
The collector still owns aggregation, completeness and publication.

`SpeakCore/DataMigrationPreferenceCatalog.swift` is the sole key/category/kind
authority: 89 accepted canonical preferences plus seven auxiliaries, not a
second desktop catalogue. `trackedKeyIdentifiers` and
`transcriptionKeywordsLastReconciled` remain excluded. Vocabulary and connections
partition through that catalogue; the bridge never reclassifies them as settings.
Unknown configuration entries and wrapper fields are named in notices, not
dumped as arbitrary archive keys. Credential-default values are excluded even
when retained in a configuration dictionary. No credential APIs are invoked.

Every `SettingsValues` authority is accounted for below. The implementation
sources are `DesktopHostSettingsValues.swift`, `DesktopHostPreferenceArchive.swift`,
`DesktopHostNativePreferenceProjection.swift`, `WindowsPreferenceArchive.swift`
and `LinuxPreferenceArchive.swift`; Mac wire names are established by
`AppSettings.swift` and the shared application-key/catalogue definitions.

| Native authority | Canonical projection or explicit boundary |
| --- | --- |
| Explicit active `model` | The existing desktop batch/live registries and shared local-family resolver select `transcriptionMode` and the active model key. Unknown/Apple-only routes are reported, never guessed as batch. Multi-purpose models remain batch when admitted by the batch registry. |
| `batchModel`, `liveModel`, `localModel` | Stored model slots map to their canonical model keys. An explicit active model wins over its corresponding remembered slot. Local engine/source submode is not invented. |
| `postProcessing.mode`, `.modelIdentifier`, `.temperature` | `postProcessingEnabled`, `postProcessingModel`, `postProcessingTemperature`; explicit native options override stale configuration mirrors. |
| `postProcessing.outputLanguage` | Stored text, including explicit empty text, maps to `postProcessingOutputLanguage`; native nil suppresses a stale mirror without inventing a replacement string. |
| `postProcessing.customPrompt` | Native-only notice; it is outside the canonical 91 keys and is not silently discarded or stuffed into another setting. |
| `appearance` | Native system/light/dark maps to canonical textual appearance, not the native integer encoding. |
| `runAtLogin` | Explicit recorded boolean only; no OS registration query or side effect. |
| `automationEnabled` | Explicit `enableAutomationServer` boolean; no service admission or permission change. |
| Windows `textOutput` | smart/direct-only/clipboard-only map to smart/accessibilityOnly/clipboardOnly; cursor/replace-field map to insertAtCursor/replaceAll; restoration retains its explicit boolean. |
| Linux `textOutput` | Clipboard-only maps exactly; native paste has no exact Mac method and is reported instead of relabelled smart. Restoration retains its boolean. |
| `hotKey` | Exact shared Mac activation styles map to `hotKeyActivation`; press-to-toggle/unknown styles are native-only, never fallback conversions. Windows virtual-key bindings and Linux portal/fixed bindings do not become Carbon `selectedHotKey` data. |
| `voiceOutput` | Only explicitly stored auto-play/save/speed/pitch/SSML values overlay their five canonical keys. No execution getter, default materialization, clamping, provider selection or synthesis occurs. |
| `voiceOutput.modelID`, `.voiceID`, `.trackUsage` | Native-only notices. The desktop provider/model/voice tuple is not assumed to equal Mac `defaultTTSVoice`; usage tracking is not a new canonical key. |
| `microphoneDeviceID` | Native-only notice; a native device identifier is not reinterpreted as a Mac audio-input UID. |
| `localUseGPU`, `azureSpeechResourceEndpoint` | Native-only notices; neither belongs to the canonical application-key set. |
| `configuration.values` | Selected, known records are retained and type-validated using the canonical catalogue. Each retained value is explicitly distinguished from a native-authority overlay; retention does not prove execution support. |
| Unknown top-level `Settings` fields | Names are reported; values remain in the existing settings wrapper, not in canonical records. |

This rule covers every canonical preference without copying its entries:
explicit native projections win, remaining known configuration values retain
their catalogue category/kind, the two excluded canonical keys are reported,
and absent values stay absent. Editor defaults (`value(for:)`), platform
fallback shortcut getters, effective Voice defaults and the restricted portable
configuration exporter are not used to fill missing values. New settings track
whether their otherwise implicit active model/slots were explicitly set; stored
model keys are explicit on decode. Startup normalization preserves that presence
metadata without changing runtime selection or existing Codable encoding.
Optional Voice fields retain legacy opaque values
when no explicit native replacement exists, with a retained-value notice.
Projection does not mutate mirrors, Voice, providers, controls or settings files.

All emitted records pass canonical scalar shape/finite-number validation.
Archive-valid but currently unexecutable Voice values remain raw for recovery,
not clamped into a different preference. `ttsPronunciationDictionary` is decoded
as `[String: String]` and emitted as structured `jsonDefault`; a JSON string or
base64 blob is not equivalent. Apple shortcut JSON requires an explicit typed
validator supplied by its owning collector; without one it is reported and
excluded, not accepted by an object-shape guess. Validator failure aborts the
projection rather than returning success-shaped partial records.

The local candidate passes 85 focused preference/Voice/hands-free/tail tests
(23 new projection regressions) and the complete portable suite: 1874 tests,
30 skipped, zero failures. Strict pinned SwiftLint passes all 17 candidate
and composition-resolution Swift inputs. All four Windows Swift projections
pass, including the production Windows projection hook and host tests. Those
header-backed projections do not prove native linking or runtime behavior;
there are no new native/Apple or installed-app receipts for this candidate.

Known limitations remain visible: no raw-file preservation guarantee for values
already changed by existing startup migrations or unknown members discarded by
existing nested typed decoders; no synthesized
Mac shortcut/Voice identifier, device UID, local submode or prompt record; no
collection-store collection, credential access, default reset semantics,
import/mutation, or atomic destination publication. The parent must preserve
category completeness and unknown/native-only material deliberately rather
than feeding these partial arrays into destructive replacement.

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
Dictation and Voice transfer key projections now reuse the parent's exact
canonical application-key definition; this does not import its migration
catalogue or make all 91 preferences executable.
This is **transfer support, not executable Voice acceptance**: Generate,
retained results and the native Voice controls remain in #1217.
Voice flags do not increase this slice's editable preference count. There are fourteen
previously accepted preferences plus three recording-sound preferences now
qualified natively below; installed-package sound acceptance is still pending.
Four additional dictation preferences now have executable desktop behavior;
their qualification and platform differences are recorded separately below.

The published `VoiceSynthesisOptions` contract from #1217 now validates transfer
of `ttsSpeed`, `ttsPitch` and `ttsUseSSML` into that same model. Transfer-only
metadata reuses its bounds/defaults and canonical application keys, not a second
provider catalogue or native editor. New imports require finite speed in the
shared range, whole-number pitch in the shared range and strict SSML booleans;
shape validation is separate from provider execution admission.
Partial imports preserve absent fields, IDs and already stored unsupported or
out-of-range values. Export projects raw stored material for recovery rather
than clamping it or calling a throwing execution getter. Invalid new imports
and write failures change neither dictation nor Voice settings.
Absent new model fields do not erase older opaque configuration values during
export; those values remain unapplied until explicit validated transfer.
This branch still offers only its existing Deepgram Read aloud choices: it
explicitly refuses unsupported/nondefault or invalid synthesis controls before
creating playback or reading credentials. Voice selection itself preserves stored options
without an implicit reset. Azure execution and native advanced
controls remain in #1217; no inert speed/pitch/SSML controls are added here.

The final synthesis-transfer slice passed 26 focused portable tests and the full
portable suite (1417 tests, 28 skipped, zero failures). All four Windows Swift
projections and strict lint across ten changed Swift files passed. These are
shared behavior/projection receipts, not new native editor or installed-package
acceptance; the native recording-feedback receipts below remain tied to their
explicit earlier commits.

Generated audio archival follows the parent's app-owned destination: the actual
`DesktopRecordingStore.directory`, as a flat canonical `UUID.wav` without a
transcript journal entry. This participates in the parent's audio-only cleanup;
separate generated-result cache/playback staging does not. Foreign imported
`recordingsDirectory` values are never executed. UUID filenames replace the
Mac's colon-containing timestamps on Windows. Native archival and Voice
acceptance belong to the Voice/parent workstreams, not this defaults extraction.

## Hands-free and silence execution

The native Transcription editor now exposes `handsFreeDictationEnabled`,
`silenceDetectionEnabled`, `silenceThreshold` and `silenceDuration`, using the
same canonical keys and Mac meter/default/range definitions. This increases the
editor to 21 preferences, not 21 fully accepted product features.
`DictationSilencePolicy.swift` owns the PCM meter's -60 dB scale, 0.7 RMS/0.3 peak
weighting, 0.05 threshold and two-second hold. Manual auto-stop includes initial
quiet and uses the existing recording buffer, provider finalization,
post-processing and insertion pipeline; manual Record stays manual even when
the hands-free preference is enabled.

Windows/Linux hands-free is explicitly **sound activation, not Apple's ML speech
classifier**. Noise can trigger it. The existing pure `HandsFreeDictationMachine`
and activity tracker now compile portably; unchanged Apple classification,
sensitivity and model admission live in `HandsFreeDictationApple.swift`.
The native hotkey arms/disarms, sound starts an utterance, configured silence
finishes it, and successful transcription rearms the same native capture only
after record-bound output confirms field insertion or an explicitly requested
clipboard copy. `DesktopTextOutputResult` separates delivery evidence from status
copy: accepted paste keys, fallback recovery copies, failures and cancellation
never authorize automatic rearm. The last completion survives output-slot cleanup
without retaining its native job, and cannot acknowledge a different recording.
Capture/provider/post-processing failures, Cancel, Record, committed configuration
changes, lock/sleep and close disarm. A refused start or user-absence event never
cancels a manual recording.
Each sound-start captures a fresh native destination off the PCM callback and UI
thread, then freezes it through transcription/output. Windows retains the
captured field; X11 retains/rechecks its window. A missing/refused destination
stops hands-free rather than delivering to a different field. Wayland cannot
freeze another client's destination, so automatic utterances require explicitly
selected clipboard-only output; manual portal paste remains available.
Windows requires verified insertion into the retained native edit control, or
verified UI Automation insertion with field identity, to rearm. A window-only
paste does not qualify.
X11/portal key submission is not text readback: it reports unconfirmed insertion,
stops listening and asks the user to check the original field before rearming
with the hotkey. There is no automatic retry that could duplicate uncertain text.
Capture-target completion after disarm/close cannot start a late recording.

Each Windows utterance now resolves the fresh captured application's profile
through the canonical resolver. Its model, language and polish choices remain
record-bound; no override is persisted into app defaults. Explicit clipboard
output still resolves the current app without probing an editable field or
creating an insertion worker. Unavailable models refuse the utterance without
fallback. A route requiring a different PCM rate disarms before creating a WAV
or starting a provider, with guidance to arm again in the destination app.
The preferred microphone and output method remain detector/run-owned.

Recording configuration, live options, Azure endpoint and capture rate are
snapshotted before asynchronous startup and retained through finalization.
Linux uses fresh default settings, not a fictional Windows-path match:
the canonical matcher currently has no Linux executable-path kind, and Linux
has no native profile editor. X11/Wayland recordings explicitly retain that
default-only limitation in their profile notes. Unsupported imported profiles
are preserved. A Linux matcher/editor/archive-compatibility follow-up remains
necessary for actual Linux profile parity.
That matcher/editor/archive follow-up is tracked separately in #1219.

`DesktopHandsFreeAudio.swift` keeps quiet pre-roll only in RAM (0.5 seconds).
Startup audio is bounded to three seconds; overflow fails and disarms rather
than silently losing first words. Quiet listening creates neither History/WAV
nor a provider session. Each utterance uses the existing WAV/provider sink;
stopping joins that sink before finalization without restarting the detector.
Automatic recording cues are muted only during sound activation to prevent
self-triggering. The armed run reserves the existing independent feedback
channel, cancels/stops an earlier preview before microphone startup and refuses
new previews until disarmed. No audio IPC, disk polling, native inference/resampling
replacement, recording-directory change or Voice persistence mirror is added.

Arming requires native session monitoring. Windows observes WTS lock,
disconnect/logoff and power messages and verifies initial session/input-desktop
state. Linux observes logind sleep/current-session state and an existing
GNOME/freedesktop screen service, subscribing before querying initial state.
Independent absence bits prevent unlock from clearing sleep (or wake from
clearing lock). Lost buses/services or invalidated session state fail closed.
Missing access/monitoring disables enabling a new native mode with an explanation
and refuses runtime arming. A previously saved enabled mode remains editable so
users can turn it off and restore manual shortcuts; its value is not silently
discarded. Manual recording still works. A failed monitor needs an
app restart, not an unprotected automatic retry. Flatpak permissions are
unchanged; its installed session-monitoring availability is unqualified.
Linux settings retain native scrolling. Windows now scrolls fields/recovery
controls while keeping the section, error region and footer fixed; wheel,
scrollbar and Page Up/Down make the last fields reachable.

The frozen f29 runtime tree passes 99 focused hands-free/configuration/feedback
tests and the full portable suite (1436 tests, 28 skipped, zero failures), all four Windows Swift projections and
strict lint across the 29 changed Swift source/test files. The boundary check
reports 275 shared sources and 110 explicit Apple exclusions; canonical-key
coverage remains 91/91. Local production Win32 control fixtures pass grouped validation, recovery,
scroll-to-end, fixed-footer bounds and guard-disabled state. Production GLib
fixtures pass independent lock/sleep state and service-loss refusal. Changed
native C/C++ syntax passes. These synthetic/native-control receipts do **not**
prove real microphone latency, real OS lock/sleep delivery, ambient-noise
quality, Apple compilation or installed-package acceptance. Exact-head CI and
physical/device qualification must be reported separately.

The subsequent target/delivery slice passes 50 focused host tests (including
nine new delivery/target lifecycle cases), the full portable suite (1445 tests,
28 skipped, zero failures), all four Windows Swift projections and strict lint
across 24 changed Swift files. An initial full run exposed the existing unrelated
OpenRouter cancellation error-shape race; its unchanged eight-test suite and the
full rerun passed. Native Windows tests additionally classify retained-control
versus UIA/window-only proof, and native Linux tests classify accepted keys,
explicit copy and fallback copy; those require separate exact-head native CI
receipts, not substitution of the frozen f29 receipts above. No native control
IDs, events, C headers, clipboard ownership algorithm or icon assets changed.

Frozen target/delivery head `7fb5b546c633ab286c83245dac9c493c7feaca0f` subsequently
passed exact-tree native Windows x64 and ARM64 (each 1666 tests, 62 skipped,
zero failures) and Linux (1547 tests, 29 skipped, zero failures), including
the actual disposable-session integrations. All three checked out
`cffe28a92cf2c41ac440e8e14d5c7b1d1b09267e`, whose complete tree equals that head.
The later profile/configuration slice needs its own receipts; these are not
qualification of subsequent source. Its additive Windows foreground-path ABI
does not change insertion/clipboard ownership or native control IDs.

The bounded profile/configuration slice passes 70 focused tests (eight new
actual-host profile/configuration cases), full portable 1453 tests with 28
skipped and zero failures, all four Windows projections and strict lint across
15 Swift inputs. The actual Windows guarded-output/clipboard/profile fixture
also passes locally: process identity, bounded workers, short-buffer failure
and exclusion of this app's own process. Its private MinGW header lacks the
standard read-only UIA attribute ID, so the local fixture compile supplies
that SDK constant; official-SDK native/Apple acceptance is separate.
No microphone/installed-package or complete Linux app-profile claim follows
from these synthetic and local receipts.

## Recording feedback (native qualified; package acceptance pending)

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

These three preferences are **native qualified, not fully package accepted**.
At `ec1dece9`, Windows x64 job `115579777652` and ARM64 job `115579734131`
each passed 1625 tests (62 skipped), production decoding of all eight AACs,
native executable/window self-tests and on-device transcription. Linux job
`115580139101` passed 1505 tests (29 skipped), all eight AACs, GTK/Wayland
checks, the private PipeWire integration and four Windows Swift projections.
All three native jobs had zero failures.

Windows x64 and ARM64 builds and all eight AAC decodes also passed at `cf4779d1`.
Its Windows developer bundle also decoded all eight production assets on the
local host; the real default endpoint admitted both cues in every profile in
2.394-6.934 ms and passed reusable stop/joined close. That local run used the
existing installed Swift runtime, not a newly installed self-contained bundle.
The CI MSIX bundle/native self-tests passed, but the lifecycle readiness probe
rejected the nonfatal no-audio-device warning. The bounded actionable warning
retains the full error in stderr and does not disable capture.
The earlier Linux run built and decoded all eight AACs, then failed a fixture constructed
at unsupported 8 kHz before reaching its intended decoded-duration check; the
corrected 16 kHz fixture passed at `ec1dece9`. Its warmed dedicated libpulse
channel admitted both cues for all four profiles in 0.078-0.135 ms on the
private PipeWire sink, below the 100 ms bound. This is not audible latency.
The bounded warning is fully visible in both native General captures;
these captures do not show the preferences modal.
Apple CI, the corrected MSIX lifecycle and installed Linux/Flatpak
resource/codec qualification remain pending. Linux deployment composes the
sibling collector in
#1212 and needs AAC decoding (Ubuntu: `gstreamer1.0-libav`).
That collector depends on the icon workstream's staging foundation; it is not
a standalone settings patch. GNOME Flatpak runtime AAC support must be checked
in the installed app, not inferred from Ubuntu CI.

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

This transfers the portable preferences above and projects five Voice scalar
preferences when a Voice model has been saved. A legacy document with no Voice
keys leaves existing options unchanged. Hosts without the transfer contract
preserve those keys without applying them. Provider compatibility is checked
before execution, not inferred from successful transfer. Other Voice options
such as quality, language and pronunciation remain opaque and unapplied here.
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
| ttsSpeed | Transfer wired; workflow separate / Same | Canonical validation and sole-model transfer; incompatible Read aloud explicitly refused; native advanced editor/Azure execution in #1217 |
| ttsPitch | Transfer wired; workflow separate / Same | Shared integer/range validation, raw recovery export and partial-import preservation; no native pitch editor in this slice |
| ttsQuality | Missing / Missing | No quality editor/provider options |
| ttsOutputFormat | Missing / Missing | Read aloud uses native staging format |
| ttsAutoPlay | Transfer wired; workflow pending / Same | Strict canonical boolean projects to the sole Voice model; explicit Read aloud remains playback; Generate acceptance belongs to #1217 |
| ttsSaveToDirectory | Transfer wired; workflow pending / Same | Strict boolean projects to sole Voice model; generated WAV archival uses actual owned recordings directory in #1217, never an imported foreign path |
| ttsUseSSML | Transfer wired; workflow separate / Same | Strict boolean transfer; existing Deepgram Read aloud refuses SSML before credentials/playback; executable Azure/native editor in #1217 |
| ttsFavoriteVoices | Missing / Missing | No voice favourites |
| ttsPronunciationDictionary | Missing / Missing | No TTS pronunciation editor/pipeline |
| historyFlushInterval | Missing selector / Missing selector | History is durable per operation, not configurable timed flush |
| silenceDetectionEnabled | Executable; qualification pending / Same | Native switch; initial quiet and configured silence stop the existing manual recording/finalization pipeline |
| handsFreeDictationEnabled | Sound-activation replacement; per-slice qualification / Same | Fresh target and Windows app profile per utterance, immutable provider options, record-bound output evidence; rate changes refuse/rearm; Linux profiles remain default-only; not Apple's classifier |
| silenceThreshold | Executable; qualification pending / Same | Canonical range/default and Mac PCM meter; native editor feeds manual silence and sound activation |
| silenceDuration | Executable; qualification pending / Same | Canonical hold/range feeds manual auto-stop and hands-free debounce; existing recording tail is retained |
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
| recordingSoundsEnabled | Native qualified / Native qualified | General + owned native channel; normal readiness/finish cues only; installed-package acceptance pending |
| recordingSoundProfile | Native qualified / Native qualified | Canonical four profiles + owned preload replacement and explicit previews; all eight production AACs decoded on Windows/Linux |
| recordingSoundVolume | Native qualified / Native qualified | Strict 0...1 field + Mac volume-squared gain; native tests and queue bounds passed; installed-package acceptance pending |
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
