# Desktop settings coverage

This is a settings slice, **not full Windows/Linux feature parity**. Baseline:
macOS `AppSettings.DefaultsKey` aliases the shared 91-key
`ApplicationPreferenceKey` (`Sources/SpeakCore/ApplicationPreferenceKey.swift`),
plus preferences and collections
outside that enum. Track remaining product acceptance in #1157.

## Correction learning preferences (source only)

GTK now presents the canonical learning enable/threshold fields directly above
the Corrections editor instead of burying them in General. Windows Corrections
has a Learning preferences button that opens the existing Corrections preference
group. Both reuse the existing revision-aware preference authority and save
path; there is no second settings store or implicit session approval.
Linux observational learning still requires separate local session consent.

Authored native fixtures check GTK row ancestry, Windows page scope and initial
Corrections group selection, and saving without losing hidden preference values.
These changes have not been executed locally; automatic native CI and actual
installed learning workflows remain required before claiming acceptance.

## About and manual updates (source only)

Native About now shows the installed app's version/build when stamped,
configuration, source commit when present, and platform distribution. The
existing Windows staging metadata and self-contained bundle manifest are read
beside the executable; neither the working checkout's `VERSION` nor a Mac
release is used as the installed desktop version. Missing stamps are labelled
explicitly. Malformed or oversized metadata produces a visible recovery
notice, not a fabricated version or silent success.

Windows and Linux retain their native branded About layout and controls.
Six canonical links shared with the Mac lead to GitHub, issue reporting,
privacy, releases, feature requests and the MIT licence. GTK links reflow at
narrow widths; Win32 uses its existing themed keyboard-accessible buttons.
Browser-launch failures are surfaced. Building or opening About never fetches
release data, installs an updater, downloads code or changes an app.

These developer previews have **manual updates**, not Sparkle or an equivalent
automatic updater. The page says so and asks users to check platform
compatibility on View Releases; it does not call a Mac release "latest" for
Windows/Linux, report "up to date", or imply that a compatible published package
exists. Unstamped Linux builds remain explicitly unversioned; a release
packaging/stamping pipeline is still required before claiming versioned Linux
distribution or automatic-update parity.

Four authored portable regression methods cover both installed metadata
shapes, invalid/oversized inputs, honest unstamped identity, visible corruption
and canonical HTTPS link invariants. Native source fixtures inspect rendered
metadata/link controls without opening a browser. These checks are **NOT_RUN**
locally under the standing execution restriction; native rendering, installed
identity and browser-launch acceptance remain unqualified.

## Voice synthesis numeric input (source only)

The native Voice synthesis fixtures additionally check empty/whitespace-only,
non-finite, trailing-junk and fractional pitch rejection with no save event,
while preserving valid numbers surrounded by whitespace. GTK now checks that
numeric conversion consumed a number **before** skipping trailing whitespace;
previously a whitespace-only pitch could be accepted as zero. This source fix
and the Win32/GTK regression assertions are **NOT_RUN** locally.

## Cleanup mode disclosure (source only)

The Windows cleanup dialog no longer claims that post-processing has no
streaming route. Its mode label follows the selected source/model: remote
finished-transcript cleanup can stream previews, while built-in rules and
downloaded local LLM cleanup remain completed-only. An unavailable selection
asks for a supported model instead of implying an executable route. This is
distinct from Auto-Clean during live dictation; no provider request, setting
default or model capability changes.

Authored Win32 fixtures check local rules, downloaded models, remote selection
and unavailable-model labels. They are **NOT_RUN** locally.

## Modulate live and batch feature controls (source only)

At `ca2d39fb`, completed portable Linux (2,909 tests; 33 skipped) and macOS
(2,813; 55 skipped) each reported 19 failures on synthetic merge `b432351c`
into `0b4ffd7`. Three new Host fixtures used the nonexistent batch identifier
`modulate/velma-2-stt`; they now use the existing canonical
`modulate/velma-2-stt-batch`, with no production alias or route added.
Generic metadata tests also assumed that only app-switch choices could have
an empty editor sentinel and that every choice persisted a string. Their
assertions now distinguish the four Modulate default sentinels and assert
boolean acceptance/string rejection explicitly. These source repairs are
**NOT_RUN** locally; the failed jobs remain failed evidence.

At preceding head `c4677631`, portable Apple (2,779 tests; 55 skipped),
portable Linux (2,875; 33 skipped) and native Linux's Swift suite (3,019;
34 skipped) all passed with zero failures. These jobs used synthetic merge
`826d2a8` into `0b4ffd7`; they do not qualify the newer Modulate/warm-up source.
The native Linux job then failed its generic configuration Apply fixture.
That fixture incorrectly limited every non-Auto-Clean choice to three/four
items and the payloads `expanded`/`bubbly`. It also treated all optional
empty choices as one shared selection. The source repair checks each actual
catalogue's exact item count and exact emitted identifier, exercising every
optional empty independently, all existing Apply/preview/recovery actions,
and availability/title retention. Boolean dependencies are checked as switches,
not cast to editable text. Stage-specific failures now identify the offending
field/assertion. Production configuration parsing and Apply routing are unchanged.
The repaired native fixture has **NOT_RUN**.

At published `5d180aa4`, automatic portable Linux (2,903 tests; 33 skipped)
and portable macOS (2,807; 55 skipped) each reported the same two failures,
using synthetic merge `60704fa1` into `0b4ffd7`. One assertion still expected
Auto-Clean fields to be the final fields after the new Modulate controls were
appended; the revised assertion checks both complete ordered blocks. The other
exposed a real classification bug: the transient native warming approval action
was included in persisted supported preference keys. That projection is now
excluded, while the canonical warming intent remains supported. The existing
strict canonical-key assertion is retained, with explicit intent/approval
classification coverage added. These repairs are **NOT_RUN** locally and do
not imply either failed job passed.

The four canonical Modulate booleans are native Transcription preferences for
standard batch and live transcription. Each native choice offers the existing
default, Enabled or Disabled. Only explicit choices persist a boolean; selecting
the default removes that override rather than persisting an empty string.
Apply/import/export/Codable restart retain strict boolean storage authority;
the native empty sentinel is never accepted as a stored string.
Old root settings are adopted only when nested configuration lacks that key;
nested values win, and the root copy is removed.

Absent values retain the previous per-route defaults, including after unrelated
Apply: batch speaker identification is on, live speaker identification is off,
and the other features are off. The speaker choice explains this difference.
Explicit values affect both routes. Mac defaults remain unchanged. English Fast
does not support these advanced flags and its existing client omits them.

Recording profiles snapshot batch features alongside live options. Normal
recordings, imports, History retries, owned recording admission, automation
file requests and vocabulary reconstruction preserve the snapshot. Both native
adapters pass the whole request into prepared audio handling, including
conversion. Windows now also retains that request's existing `historySaved`
authority instead of dropping it. Comparison admission snapshots the same
flags for live and batch lanes, without adding normal keywords, post-processing,
vocabulary or automatic insertion to raw comparisons. Existing public profile
and package request initializer arities and prepared-audio overloads are retained.

Authored regression methods cover all 16 feature combinations through actual
batch multipart and live query generation, native default/reset choices, strict
stored types, recording/import/retry and comparison snapshots, automation
vocabulary reconstruction, root/nested precedence, transfer/restart and
refused-write atomicity. All new product checks are **NOT_RUN** locally.
Native rendering, provider behavior and installed-package acceptance remain
unqualified. Linux's old "no streaming route" cleanup subtitle is also corrected:
remote finished-transcript cleanup can stream previews; local cleanup cannot.

## Legacy pronunciation native editor (source only)

The Pronunciation surface now links to a separate **Legacy word dictionary**
editor on Win32 and GTK. It exposes the Mac's `ttsPronunciationDictionary`
word/pronunciation map without converting it into modern pronunciation entries.
Both use the incumbent list/search, native labelled fields, New, Save, Delete
confirmation and loading/error feedback. GTK retains its native page column;
Win32 retains its list/detail layout. Imported multiline text is editable
without flattening it. Fields and search are disabled while a legacy request is
pending, then restored for success or retry, so a delayed response cannot
silently replace new typing. A selected entry's original word/value identity travels
with each edit: stale edits/deletions and renames onto an existing word are
refused rather than overwriting newer values. New duplicate words require
selecting the existing entry.

The Host changes only the canonical map through the existing persist-only
configuration path. It does not request keys, authorize cleanup/probes, copy
pronunciations into recognition hints, alter suppression/explicit keywords or
mutate the modern Read aloud store. A dictionary with NULs, native fields over
65,535 UTF-8 bytes, or an over-4-MiB presentation is explicitly refused for native
editing and remains intact for portable preference export; there is no lossy
truncation. Read aloud continues to use the existing modern rendering pipeline;
this legacy editor does not claim a new legacy phonetic synthesis route.

Four authored Host methods cover CRUD, restart/export, modern-store and unknown
preference preservation, credential isolation, stale rows, collisions, malformed
events/display bounds and refused-write retry. Native source fixtures check the
four-field escaped payload, original identity, delete and New behavior.
These new product checks are **NOT_RUN** locally; native installed acceptance
and full parity remain incomplete.

The preceding `054a3385` automatic Linux portable job `118098795757` ran 2,927
tests (33 skipped) with three failures. Native Windows job `118099016759` also
reported the same three failures, all in the new Host pronunciation tests:
they looked up nonexistent field key `shortErrors` rather than canonical
`ApplicationPreferenceKey.shortenErrorDisplay`. The source now uses that
canonical key; this repair is **NOT_RUN** locally. Both legacy whole-profile
expectations repaired in `4bc5e723` passed in the completed Linux log. Neither
failed job is labelled successful.

## Modern pronunciation recognition capture (source only)

At `76bd3d78`, completed portable Linux (2,918 tests; 33 skipped) and macOS
(2,822; 55 skipped) compiled and executed this capture source using synthetic
merge `dafed1f538699bddca1cf8769074f8750e6ee297` into `0b4ffd7`. Each reported
the same two held legacy-event profile equality failures: expected profiles
still had unresolved pronunciation options, while admission now freezes words.
The revised tests derive that frozen selection from a pre-delivery vocabulary
snapshot and retain whole-profile comparisons plus every original consent,
credential, cleanup, preview and output assertion. These source repairs are
**NOT_RUN** locally; neither failed job is labelled successful. This evidence
does not qualify the newer native editor projection below.

Desktop AssemblyAI recognition now combines explicit terms, literal modern
dictionary words and sorted legacy dictionary keys through the shared Mac
policy. Regex entries, spoken pronunciation text and TTS replacements are not
recognition seeds. Ignored words remain suppressed, explicit reselection wins,
and the existing character/count bounds and case-insensitive uniqueness apply.
Automatic seeds never enter the shared keyword preference or other providers'
requests. Raw comparisons remain deliberately free of dictionary seeding.

First-party desktop defaults/configuration explicitly opt in to this policy.
Existing public `LiveClientOptions` initializer signatures and explicitly
constructed options retain their former behavior. A value snapshot captures
the selected/legacy/ignored preferences before asynchronous vocabulary work,
then freezes modern words once admitted, including an empty dictionary.
Vocabulary copying preserves that snapshot and provider controls. Ordinary
recordings freeze it before capture; owned capture uses its existing input
snapshot. Live startup, completed transcription, import/retry and read-only
automation file commands resolve the same policy without rereading changed
settings after suspension. Failed vocabulary reloads refuse stale hints.

When native keywords are edited while AssemblyAI is selected, clear and
reselection reconcile modern and legacy suppression together. Unrelated
Apply and other providers do not infer new modern suppression. If the selected
model, preferences or recording state changes while hints load, Apply refuses
the stale edit explicitly. Preview/recovered-keyword persistence uses the same
reconciliation without granting fresh cleanup or warming approval.

Authored checks cover the real injected AssemblyAI query, captured ordering,
empty snapshots, old initializer arity, literal/regex/replacement separation,
reload failure, normal recording/import/retry, owned input, native clear,
transfer/restart and read-only automation. New product execution is **NOT_RUN**
locally. Legacy-dictionary editing and actual provider/native/installed
acceptance remain gaps; this is not full parity.

### Native pronunciation hint presentation (source only)

Windows and Linux now use the same Host native editor snapshot to populate the
existing AssemblyAI field with effective explicit, modern and legacy terms when
AssemblyAI is selected. The shared keywords field remains explicit-only.
Loading this projection never writes settings or reads provider credentials.
The older raw configuration/Voice snapshot APIs remain unchanged.

The display snapshot is separate from persisted preferences. Both native
adapters acknowledge its view identifier through the native callback, after
Win32 snapshot registration/active control replacement or GTK's queued row
application, not when the GTK update is merely queued. Apply, preview
and recovered-keyword actions refuse an unrendered or superseded snapshot, or
one whose model/preferences have changed. Every edit carries its actual native
view identifier; equal-looking fields cannot authorize a queued older view.
The old native registration APIs retain their original callback shape.
Win32 save-and-preview blocks further edits until active controls are replaced
and acknowledged; its language-only updates still preserve unsaved values.
An unchanged projected AssemblyAI field is restored to its canonical explicit
value before reconciliation, so
unrelated Apply/persist-only cannot leak automatic seeds into shared keywords,
exported settings or suppression. Deliberate clear/reselection still follows
the shared suppression policy. Dictionary changes preserve unedited fields;
a keyword edit from a changed dictionary snapshot requires reopening settings.
Failed writes preserve both settings and the retryable editor authority.
If the combined projection exceeds the existing 65,535-byte field limit or
contains a NUL that native controls cannot represent, the editor explicitly
reports that it is showing saved keywords only. Raw values and automatic
recognition policy remain intact; they are never silently truncated.

Nine authored Host methods cover strict shared native event decoding, view
identity, display-only behavior, credential isolation,
Apply/persist-only and restart, clear/recovered selection, unrendered and
superseded snapshots, stale preferences/model/dictionary, non-AssemblyAI
presentation, native display limits and refused-write retry. The Win32 fixture
also checks active control replacement, acknowledgement and stamped Apply;
GTK fixtures assert the actual rendered revision before checking their unchanged
field and recovery payloads. New native/Host checks are **NOT_RUN** locally;
native rendering and installed acceptance are still unqualified.

## Legacy pronunciation recognition hints (source only)

The preceding `9be6c8aa` automatic Linux/Apple-portable/Windows ARM64 suites
reported the same 13 assertions across seven test cases: old expectations did
not distinguish the new explicit streaming export/editor projection from sole
stored configuration. Updated expectations retain whole-value comparisons,
explicit false, local-only behavior and immutable capture-policy checks.
Windows x64 additionally exposed a synthetic self-test ordering defect: capture
of the original field now precedes moving focus to the destination. Production
focus validation and all app-switch refusal assertions are unchanged. These
source repairs require new-head CI; old failed runs do not qualify them.

The Mac's pronunciation-to-AssemblyAI keyterm policy now lives in SpeakCore:
modern words precede sorted legacy words, case-insensitive duplicates are removed,
invalid seeds are excluded, explicit terms win, ignored seeds stay suppressed,
and the final list has at most 100 entries. Mac Settings uses this same policy
without changing its existing model guard or synchronization events.

Desktop configuration now validates the canonical `ttsPronunciationDictionary`
as a word-to-text JSON object and `assemblyAIIgnoredPronunciationTerms` as a text
array. A transferred dictionary contributes **its keys only** to captured
AssemblyAI live/completed recognition options; phonetic values are never sent as
recognition terms or copied into the modern pronunciation/TTS replacement store.
Native startup adopts these two keys from old root settings when absent from
nested configuration; nested values win. Other providers' configured keywords
are unchanged. Raw dictionary values,
suppression and unrelated future preferences survive configuration apply and
Codable restart/transfer. An absent dictionary preserves existing desktop option
behavior. Explicit native keyword edits update legacy seed suppression so a
deliberate clear is not silently undone; unrelated preference applies do not
change suppression. Explicit recovered-keyword selection follows the same rule.

This section describes the earlier legacy-only slice. The modern capture source
above extends it; neither slice is a native editor for the legacy dictionary or
evidence of provider/native/installed acceptance. New source regressions have not
been executed locally; automatic CI remains required.

## Finished-transcript streaming cleanup candidate (source only)

The canonical `postProcessingStreamingEnabled` boolean is now exposed by the
existing native Post-processing preferences. It applies to **remote cleanup of
a finished transcript**, not to live transcription, Auto-Clean, Voice synthesis
or external text insertion. Windows and Linux use the existing portable
OpenRouter client and bounded HTTP delegate transport with a real `stream: true`
SSE request. There is no completed-response buffering presented as streaming,
provider substitution or automatic retry after an uncertain failure.

The Mac's absent-key default remains true, now named once in `SpeechDefaults`.
For compatibility, existing desktop `Options` initializers and documents without
the new field retain their previous one-shot behavior (false). The Host projects
that effective value into the native editor even before options have been
created; merely applying unrelated settings therefore does not turn streaming
on. A previously retained canonical boolean is adopted on load when no explicit
Options value exists; an explicit Options value wins over an old mirror. Apply,
restart and JSON transfer use Options as the one runtime authority. Unknown and
dormant configuration values survive, and importing the streaming preference
does not authorize a remote route, Auto-Clean or downloaded-model execution.

Each recording captures its resolved cleanup options and dedicated credential
in memory at legacy/owned admission; imports and retries capture at the start
of their transcription attempt. Prompt, context and request identity are fixed
before the cleanup task starts. Only accumulated previews reach the native
window and owned HUD. A latest-value dispatcher and native single-pending-value
queues avoid a token-task or UI-message backlog. The window's separate preview
ticket is retired by native page/record/version changes, including away/back,
as well as Host cancellation, close and replacement. Preview text is not a
History record or a Copy/export/read-aloud/automatic-output source. The HUD
still follows its recording when a different app page is visible and respects
the existing HUD visibility/live-text preferences.

Only a nonempty, successfully terminated response may become the processed
History/output result. Raw provider text and recovery audio stay separate.
Malformed UTF-8/JSON, provider errors, filtered/truncated/empty results, missing
completion, HTTP rejection, cancellation and size/deadline breaches fail
explicitly; there is no raw-as-cleaned success and no second request. Framing
accepts split UTF-8, LF/CRLF/CR, comments and multiline data. Bounds are 64 KiB
per event/line and accumulated text, 2 MiB wire data, a 60-second exchange
deadline and the existing 280-character HUD tail.

Empty/silent input makes no cleanup request. Disabled cleanup never acquires
this lane; choosing Instant does not itself enable remote cleanup. Built-in
rules and explicitly selected
downloaded LLMs remain offline, completed-only routes; this remote-only switch
does not fabricate local chunks or silently send local text to a cloud model.
Downloaded-model/runtime availability and safe external insertion remain their
existing separate capability gates.

Injectable HTTP/parser, route, settings transfer/restart and actual shared Host
callback/legacy/owned lifecycle regression sources accompany this candidate.
**All new product/parser/compiler/lint/tests/native UI/provider/device checks
are NOT_RUN and this source is NOT_QUALIFIED.** No live-provider support,
installed-native acceptance or full Windows/Linux parity is established here.

## Auto-Clean candidate (source only; validation on HOLD)

Windows and Linux share a per-recording Auto-Clean lane in `LivePolishSession`,
fed by the authoritative full `DesktopLiveSession` text, not by PCM. The existing
native **Transcription** preferences render Instant/Auto-Clean, cleanup model ID,
debounce, minimum added characters and skip-ordinary-post-processing fields.
Both native configuration adapters raise their former 32-field limit to 64 so
the expanded canonical form can actually be registered. Added native fixture
source covers Auto-Clean controls and the expanded field boundary; it is NOT_RUN.
`DesktopConfiguration` remains their sole preference authority; approval to run
the lane is device-local, separate from portable preferences. Imports preserve
the requested mode but revoke that approval. Review and Apply preferences on
this device before an imported Auto-Clean choice may read a cleanup credential
or transmit text. Instant remains the default and adds no cleanup key read,
request or network activity.

Only native Apply grants Auto-Clean approval. Start/stop sound Preview still
saves the form's sound settings and plays the selected cue, but never grants
approval. Non-Apply persistence (including keyword recovery) retains prior
approval only when Auto-Clean's effective model and processing preferences are
unchanged; changing them revokes approval until Apply. An ordinary cleanup-model
change also revokes approval when Auto-Clean uses that fallback, but not when an
explicit Auto-Clean model keeps its effective route unchanged. Both native
handlers use this shared preview path. These R2 regressions are source-only and
NOT_RUN pending admission.

The lane uses the canonical `ModelCatalog.liveCapabilities` speed-mode contract
only for implemented desktop live routes. It captures the model, profile
fallback, configuration and dedicated cleanup credential at admission. Model
resolution is explicit Auto-Clean model, then the resolved profile/post-processing
model, then `ModelCatalog.defaultFastTextModel`. Existing OpenRouter and native
downloaded-LLM adapters execute the shared minimal cleanup prompt at temperature
zero; built-in rules and unsupported routes are not advertised as LLMs and do not
fall back to another provider. Missing credentials/configuration/runtime and
invalid/empty responses are explicit failures retaining the original.

The shared defaults are 500 ms debounce and 20 added Unicode characters.
Known native numeric fields use one validated `Double` representation, including
whole-number JSON input and Auto-Clean defaults, so Apply and decode/encode retain
the same numeric entries and configuration equality. Unknown and dormant values
are not coerced, and Auto-Clean timing fields still reject fractions.
Replacements, same-length edits and retractions invalidate the previous request
without relying on length growth. Utterance finals bypass debounce. Recording
stop pauses previews; finalization awaits the authoritative provider transcript,
applies existing voice-command and vocabulary policies, and cleans that resulting
full text. Only an exact-input successful cache is reused. Cancellation, close,
provider failure and request timeout retire request identity before cancelling
workers, so a non-cooperative late response cannot overwrite a newer recording.
No LLM await or extra audio queue is added to the PCM path. Preview updates stay
inside the native window/HUD; external insertion remains the existing
captured-field-at-completion operation.

History keeps provider `result.text`, corrections, `processedText` and a distinct
`livePolishResult` (input/model/result/failure). Portable native History metadata
retains that result. Ordinary post-processing is skipped only after actual
successful final Auto-Clean when the skip preference is true; otherwise it
receives the successful cleaned text, or the corrected original on failure.
An Auto-Clean failure remains visible even if ordinary cleanup succeeds.

`livePolishTailWindowChars` is preserved but has no desktop control or consumer:
the Mac stores it in `AppSettings`, but `LivePolishManager` uses full `tailText`
and does not consume this preference either. No tail-window behavior is claimed.
Mac prompt/default/model definitions now refer to the same shared policy;
its existing manager lifecycle is not replaced by this desktop candidate.

New regression **sources** cover the injected client/scheduler, exact prompts,
Unicode/edit/retraction behavior, raw/polished history and transfer, profile and
credential capture, approval/import/restart, both legacy and owned stop paths,
native presentation, cancellation/close and malformed responses. **All are
NOT_RUN.** Compiler, lint, automated fixtures, native UI/provider/runtime/device
acceptance and safe live external insertion remain unqualified. This source
candidate is not a claim of complete Windows/Linux or macOS behavior parity.

## Window-local sidebar shortcuts

The shared `DesktopSidebarShortcut` catalogue supplies stable destination IDs and
`Ctrl+number` presentation to both native shells. General's **Show sidebar
shortcut hints** switch uses the existing `showSidebarShortcutHints` key, defaults
to true when absent, and accepts strict booleans only. Saving, restarting and the
existing desktop JSON configuration import/export use that sole persisted value.
Canonical preference transfer retains explicit false and respects selected-ID/
kind replacement coverage; this does not claim new native archive-import support.
The macOS controls, Command shortcuts and persistence are unchanged.

The native mapping is Ctrl+1 Dashboard, Ctrl+2 History, Ctrl+3 Voice Output,
Ctrl+4 General, Ctrl+5 Transcription, Ctrl+6 Post-processing, Ctrl+7 Corrections,
Ctrl+8 Pronunciation, Ctrl+9 Profiles and Ctrl+0 About. The separate source-only
Linux Profiles candidate adds the real Profiles destination and its Ctrl+9
binding together; this is not a claim of native qualification or publication.
Keyboard and iCloud Sync retain native pointer/focus navigation without invented
numeric bindings. Switching hints off removes chord text/accessibility hints,
not destination names or keyboard navigation.

### Linux Profiles candidate (source only)

The native GTK Profiles page uses the existing canonical profile store,
catalogues and per-recording resolver. It provides an ordered list, create/edit,
duplicate, confirmed delete, move up/down, and manual selection for the next
recording in the current app session. Saved profiles and their order survive
restart; the manual selection deliberately does not become a new portable Mac
preference or another runtime store. Restart returns to automatic/app settings.
If a selected profile is deleted or externally removed, the picker explicitly
shows it as unavailable and uses app settings, not a different automatic match,
until another profile or Automatic is explicitly selected.

Editable overrides are executable batch/live/downloaded-local models, spoken
language, inherited/off/on post-processing, an executable polish model including
built-in Local Rules, custom prompt, output language, and inherited/off/on lexicon
directives/context tags. Choices come from the host's canonical capability
projection. The shared Local Rules notice explicitly explains ignored prompt,
language and context controls; their dormant values remain stored.

X11 automatic matching compares only the captured target process's exact,
case-sensitive `/proc/PID/exe` path against explicit Linux executable matchers,
in user order. Missing PID/process access, sandbox boundaries or a target whose
identity cannot be captured mean no automatic match, never a title/WM_CLASS
guess. Wayland does not supply a foreign-app identity through this host; manual
selection works there, but automatic app matching does not. Existing Windows
executable and Mac bundle-ID matchers are retained, not reinterpreted.

The recording event snapshots the profile, model, microphone and text-output
selection in the existing ordered settings queue. Global shortcut recognition,
window Record and command-toggle carry that captured profile into the real
recording, including hands-free arming, without resolving later editor globals.
Profiles do not change an already running recording or the global defaults.

The Linux editor applies typed changes over the canonical raw profile document,
retaining unknown fields, unknown matcher objects and unchanged unsupported
overrides; duplicate also retains the source's unknown fields. Explicitly
replacing an unsupported route is required before it can record. A newer routing
identifier blocks desktop capture instead of being inferred as a remote route.
Transfer continues to read the preserved canonical raw file. Revision tokens and
the captured raw document reject stale editor writes; failed writes do not
publish a new runtime list.

Portable regression sources cover canonical-ID choices, CRUD/order/restart,
manual-selection capture in an actual synthetic recording, context inheritance,
raw unknown-field preservation/transfer and unsupported-route refusal. GTK smoke
sources exercise the production page/wire/actions and Ctrl+9 routing. **None of
these new tests, compilers, linters, native UI or hardware checks have run for
this candidate.** The frozen R5 Local Rules source/lint receipt is a dependency,
not validation of this later delta. This does not establish full profile,
Apple-engine, installed-runtime or Windows/Linux feature parity.

These are app-window shortcuts, not new global hotkeys. Both shells leave
editable fields and additional modifiers alone and refuse unavailable, hidden or
disabled rows. Windows also gives a configured global dictation Ctrl+number
chord priority and suppresses the conflicting sidebar hint. GTK handles keys in
the bubbling phase; the focused widget gets the first opportunity. Linux's
existing X11 dictation chord is Ctrl+Alt+Space. Wayland/compositor global
reservations remain outside this app's authority and can intercept local keys;
no portal permissions or global shortcut behavior are changed.

Native self-test cases cover hint updates, navigation with hints disabled,
modifier/editable-focus refusal and disabled/unmapped destinations. They require
execution in the actual Win32/GTK shells; portable tests and Windows C-stub Swift
graphs alone are not native UI or installed-package acceptance.

Windows retains valid bindings and the exact hint flag before its HWND exists.
Creation claims that owned snapshot under the window mutex and applies it before
READY; the existing post-hotkey refresh still suppresses reserved chords.
Live updates retain FIFO asynchronous delivery and posting errors. Mutex-owned,
monotonically identified payloads are released on delivery or teardown, so a
destroyed window cannot leave an owned message pointer or reuse an old token.
Unknown destinations, duplicate destinations/digits and malformed chords fail
without changing the retained/applied configuration. The C ABI reports allocation
or synchronization exceptions as its existing failure result.

The existing native self-test now exercises the production delivery/validation
helpers with both pre-window hint values, actual Win32 button creation, live
message dispatch, failed posting and queued-update destruction. Its ordinary
startup/settings path is not skipped; fixture compilation alone does not qualify
that runtime path or erase earlier failed native runs.

## Native layout density

General's **Layout Density** choice uses the existing `visualDensity` key and
canonical `AppVisualDensity` cases, names and metrics. The enum, geometry and
API-key query helpers are portable; only Dynamic Type and environment APIs
require SwiftUI. Apple metrics and behavior are unchanged.

Absent means Normal without manufacturing a stored value. Only exact `normal`
and `compact` strings are valid. Save, restart and portable JSON import/export
use the sole `DesktopConfiguration` value and retain unrelated unsupported
preferences. Selected-ID/kind replacement preserves uncovered density and
resets an explicitly covered clear to absent/Normal. This covers the canonical
planner and executable configuration projection, not a new native ZIP settings
application: that archive UI still inspects backups without applying settings.

Normal retains incumbent native geometry. Compact reduces page margins, card
padding, section gaps and sidebar whitespace without scaling fonts or controls.
Windows preserves its 36-DIP pointer-target baseline and removes inter-row gaps;
GTK retains at least 44 logical pixels for sidebar targets. Native editor heights,
DPI scaling, theme, shortcuts and focused text are unchanged. New GTK History
rows inherit scoped compact padding.

Windows retains pre-HWND density with the same mutex-owned, tokenized delivery
policy as sidebar bindings. The UI thread applies the initial projection before
READY, applies live messages asynchronously, and releases queued owners on
teardown. Linux uses its existing owned pre-window/UI-context update queue.
Native fixtures measure production layout functions, unchanged Normal geometry,
Compact reductions, startup retention and editing focus. Fixture compilation
does not establish runtime, multi-DPI or installed-product acceptance.
## Clipboard voice commands

General preferences expose `voiceCommandsEnabled` (default true, as on Mac) and
`clipboardInsertionTriggers` (default empty, comma-separated). Both live solely
in `DesktopConfiguration`; strict boolean/string validation also applies to
portable import. Clearing custom phrases does not remove built-in commands.
Native Win32 checkboxes/edit fields and GTK switch/entry rows retain custom
phrases while the switch disables the entry. These are General/Output behavior,
not shortcuts or permissions to control other applications.

Successful batch recordings, imported audio, transcription retries and completed
live recordings use the canonical `VoiceCommandProcessor`: expand clipboard
commands, apply vocabulary, then optionally post-process. The provider transcript
remains the Original variant. The expanded/corrected snapshot is saved before
remote polish, and subsequent History selection, Copy and Export use saved
variants without consulting the clipboard again. A transcription retry processes
the new provider result once with a fresh clipboard snapshot, never its earlier
expanded text. Live previews and failed live recovery text do not expand.
Comparison results remain raw and never read the clipboard.

As on Mac, **enabled remote post-processing receives the expanded clipboard text**
when a trigger is spoken. Clipboard contents are not added to transcription
requests, keyword hints or logs. Disabling voice commands, non-trigger text and
empty transcripts do not read the clipboard. Empty/non-text clipboards leave the
trigger unchanged. Read failures/timeouts retain raw text and audio, visibly fail
that attempt and suppress automatic output; no clipboard contents or native-owner
error details enter the failure message.

Windows reads bounded CF_UNICODETEXT off the UI thread. GTK reads an asynchronous
UTF-8 stream, capped at 1 MiB, with a 2.5-second native cancellation budget.
The Host waits at most three seconds and cancels its wait on Cancel/close even
when a native owner does not cooperate. Reads never write to the clipboard,
request a portal session or synthesize keys. X11 uses the display selection;
Wayland is limited to the clipboard access the compositor grants this client:
denial is reported, not bypassed or described as supported background access.
Portable fake tests and native header/syntax checks do not qualify real clipboard
owners, Win32 UI, GTK/X11/Wayland runtime, accessibility or installed packages.
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

The run still freezes its original per-app profile/model, device and output
options. Unlike Mac `startSession(.handsFree)`, it does **not** re-resolve the
foreground-app profile at each utterance. This remains a separate behavioral
gap; the fixed in-process capture rate is not silently reinterpreted.

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

## Local rules and post-processing context source proposal

This unpublished proposal is based on reviewed Voice Commands tree
`6207acea169f933523f2fb859c2f8cdf4c9cdbf0`. Its source and regression fixtures
have not yet been built, linted or executed. It does not establish installed
Windows/Linux UI acceptance or full post-processing parity.

The Windows post-processing dialog and Linux preference group offer explicit
**Local** / **Remote** native choices. Local exposes only the canonical
`LocalPostProcessingModel.builtInRulesModelID` option from `ModelCatalog`;
execution reuses `TranscriptPostProcessingPolicy.processLocally`, as on Mac.
Desktop post-processing still defaults to disabled. Local cleanup neither reads
nor saves provider credentials, sends requests nor installs a runtime. Empty or
`[blank_audio]` input stays empty. Cancellation retains the original transcript;
successful History entries use the canonical friendly model name.

Built-in rules ignore custom instructions, output language and lexicon context.
The native explanation says so, disables those remote-only controls, and keeps
their stored values for later remote use. Downloaded local LLMs and Apple
Foundation Models are not implemented; unknown local IDs remain unavailable
and disabled, never silently mapped to remote cleanup. Native filtered picker
rows map back to the shared canonical-ID projection; existing remote indexes
are not shifted by the appended local option.

The existing desktop post-processing options also keep a dormant
`lastRemoteModelIdentifier` for native picker recall. Explicit Remote Apply
remembers its canonical selection; Local Apply, reprojection and restart keep
that choice with the remote prompt, language, temperature and context switches.
Remembering a model never changes the active mode or grants upload/credential
permission. An unsupported remembered route requires an explicit supported
selection instead of choosing another remote model. This is private desktop
UI metadata, not a Mac preference or a second runtime store: portable export
continues to describe the actual active model and excludes the recall field.

**Include personal lexicon directives** and **Include lexicon context tags**
are now real post-processing switches, both defaulting to true like Mac.
`DesktopPostProcessing.Options` is their sole persisted runtime authority;
configuration transfer consumes supported values and removes mirrors.
Absent fields in older options use true; explicit imported false values survive
restart and export. Remote profile overrides take precedence over app defaults
in the recording's frozen options snapshot. Request filtering omits each array
when its switch is off, without deleting context saved on the record. Local
rules omit both arrays regardless of these retained remote choices. The
existing vocabulary/lexicon pipeline and Voice Commands ordering are unchanged;
the former inventory claim that no desktop lexicon pipeline existed was stale.

Portable JSON exports the model, enable choice, custom prompt and both context
switches. An explicitly enabled built-in-rules import applies locally without
credential permission; importing disabled leaves it disabled. Imported cloud
enable/model values are retained but do not grant credential or upload
permission. Unsupported local selections are preserved for export while
execution stays disabled. A refused settings write changes neither runtime
choices nor the existing file. Imports containing only context switches do not
reset the remote prompt, model, temperature or language.
The native configuration view and export project temperature/language from the
existing runtime options even when those keys were absent from a partial
context-only import; restart uses that same persisted authority.

New portable and Host regression sources cover deterministic cleanup, silence,
cancellation, credential/request isolation, persistence/transfer, strict types,
profile context precedence, frozen request omission and friendly History
identity. Production Win32/GTK self-test fixtures cover native location/model
mapping, context control labels/states, local key exclusion and unavailable
selections. These are proposed tests, not evidence that any gate or native UI
fixture has run.

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
apply. Shared keyword delivery follows the executable route table below.
Stop grace remains wired to AssemblyAI and Cartesia; vocabulary forwarding does
not change readiness, finalization, locale, annotations or post-processing.

Global terms are comma/newline separated, trimmed and stably deduplicated
case-insensitively. Provider limits are applied by shared wire clients, not
Meta's narrower parser applied globally. A recording freezes its keyword/options
snapshot with its profile, before startup suspends; changing preferences cannot
replace that snapshot. Imports and retries take the current active list once at
attempt admission, then combine it with the existing personal-lexicon keyword
projection. An explicit empty list stays empty; preserved recovery text is never
an implicit fallback. Explicit AssemblyAI options remain independent of generic
keywords for both batch and live requests, including an explicit empty override.

| Existing desktop route | Batch vocabulary | Live vocabulary |
|---|---|---|
| OpenAI direct transcription | Glossary `prompt` for Whisper-1/GPT transcription, not diarize | Existing GA transcription `prompt`, only models accepting it; no Whisper prompt |
| Groq Whisper | Shared compatible-client glossary `prompt` | No desktop route |
| Deepgram | Repeated `keyterm` for Nova-3; `keywords` for legacy Nova/Enhanced/Base | Repeated `keyterm` for Nova-3/Flux |
| AssemblyAI | Pro `keyterms_prompt`; Universal-2 `word_boost` | Existing `keyterms_prompt`, separate provider options preserved |
| ElevenLabs Scribe v2 | Repeated multipart `keyterms` | Repeated query `keyterms` |
| Speechmatics | `transcription_config.additional_vocab[].content` | Same vocabulary in existing StartRecognition config |
| Soniox | `context.terms` | `context.terms` in existing session config |
| Mistral Voxtral Mini latest | Repeated multipart `context_bias` | Explicit limitation; no qualified shared vocabulary mapping |
| Meta Muse | Existing request `keywords` | Existing session `keywords` |
| Dedicated xAI STT | Existing repeated multipart `keyterm` | Existing repeated query `keyterm` |
| Azure Speech | Existing Fast Transcription `phraseList.phrases` | Voice Live: explicit limitation; no qualified shared mapping |
| Gemini | **Not sent**: preserve word timestamps/diarization, mutually exclusive with custom vocabulary | Existing `customVocabulary` mapping |
| Cartesia, Rev.ai, Gladia, Modulate, other file/OpenRouter routes | Explicit limitation where a desktop route exists | Explicit limitation where a desktop route exists |

Unknown/unsupported mappings do not receive speculative request fields.
Scribe Medical and other unmatched model variants retain an explicit limitation,
rather than inheriting Scribe v2's vocabulary fields by provider name alone.
Unsupported keyword delivery is surfaced in recording status/History notes;
live notices use the effective run options after the lexicon merge, including
lexicon-only terms, and persist with that run without rereading preferences.
Normal transcription remains available. Gladia's custom vocabulary is
post-transcription phoneme correction, not an acoustic glossary, and is not
silently enabled. Vocabulary does not couple to clipboard/voice-command expansion.

The app conservatively bounds OpenAI/Groq glossary text to 224 UTF-8 bytes.
Individually oversized terms are omitted before the usable-term count/budget;
valid terms retain prefix truncation when the combined budget is exhausted.
Deepgram is bounded to 100 terms and a conservative 500-byte budget (without a provider
tokenizer); AssemblyAI to 100 terms of at most 50 characters; Speechmatics to
100 terms of at most 100 characters; Soniox to 100 terms/100 characters and
7,500 UTF-8 term bytes; Mistral to 100 terms/100 characters. ElevenLabs uses
at most 100 terms, each fewer than 50 characters, at most five words and without
`<>{}[]\`; terms over those bounds are omitted. ElevenLabs documents a 20%
keyterm surcharge; the app stays below its >100-term billing threshold.
Mistral context bias is optimized for English; other languages are experimental.
Existing xAI, Azure, Meta and Gemini client bounds remain authoritative.
These are synthetic shared-wire/host contracts, **not live provider API, native
Windows/ARM/Linux capture, Apple, device or installed-package acceptance**.
No credential, audio-network probe or native activation is part of this slice.

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

### Application-switch delivery

`SpeakCore/AppSwitchDelivery.swift` is the canonical three-policy catalogue.
Mac keeps its existing raw values, labels, explanations and original-app
default through the `AppSettings.AppSwitchDelivery` typealias. Native Text output
controls receive those labels from Swift; the general scalar editor uses the
same catalogue. There is no second native raw-value list.

**Compatibility is deliberate:** native `textOutput.appSwitchDelivery` is optional.
Absent intent remains legacy, not an implicit Mac default. Existing Windows/X11
captured-target output and Wayland's consented current-focus portal paste remain
unchanged. The separately labelled legacy editor choice clears explicit intent;
it is not a fourth Mac policy. Explicit imports are validated, stored only in
native output options, exported with their original value, and frozen with the
recording. Partial imports do not replace an existing policy. Startup migrates a
previously retained explicit configuration key into that same options owner.
Atomic write failure cannot publish a different destination. Explicit unsupported
intent is never silently projected back to legacy paste.

Windows original-app output can directly address a still-live Unicode Edit or
RichEdit control without activating it or touching the foreground app. Background
UIA/paste is not claimed supported: that route copies instead. Current-app
output captures a real other app/field at delivery under the original job's
cancellation owner. The child retains its own process/field and checks foreground
and focus-event revision before mutation; a second focus change, cancellation,
sensitive/stale target or ambiguous dispatch never authorizes unrelated insertion.
Speak's own UI is not a new destination. Strict original-front intent copies
instead when another app is in front. A dead original process remains an
explicit unavailable error rather than permission to redirect.

Linux's explicit policies keep guarded same-foreground X11 paste working with
captured process-start identity and a second native focus check. The existing
XID route cannot prove the original background field or safely inspect an
unrelated delivery-time field (including password/read-only status).
**Background-original and switched-current X11 targeting remain gaps**: those
requests recover to clipboard, with a visible reason. Wayland cannot identify
either destination, so every explicit app-switch policy copies only; legacy
portal behavior remains available by explicit legacy selection. GTK displays
this capability explanation in a wrapped label, not a non-rendered combo subtitle.
Imports retain the requested intent on either session type.

Clipboard recovery is never a confirmed insertion and does not automatically
resume dictation. Clipboard failure is a failure; X11 key submission stays
unconfirmed. Redirected Windows output does not grant correction learning to the
original field. Future Linux observational AT-SPI delivery must keep its own
session consent and destination provenance; these changes do not borrow either.

This application-switch packet is **source-only, qualification pending**.
Policy/configuration/transfer/restart/recording-snapshot regressions and native
adapter/chooser fixtures are authored, not run. No native behavioral acceptance
or complete three-policy Linux parity is claimed.

## Configuration transfer is not the Mac backup format

General's Import/Export preferences actions use a bounded, versioned JSON object:

```json
{"version":1,"preferences":{"preferredLocale":"en_GB","holdThreshold":0.35}}
```

Both transfers enforce a 1 MB limit. An oversized export is refused before
replacing its destination, rather than producing a file the importer cannot read.

This transfers the portable preferences above and, when a Voice model has been
saved, projects nine Voice preferences: speed, pitch, SSML, autoplay,
save-to-recordings, quality, favorite voices, and the Soniox region/language
pair (`DesktopHostVoiceConfiguration.swift:4-44`). A legacy document with no
Voice keys leaves existing options unchanged. Hosts without the transfer
contract preserve those keys without applying them. Provider compatibility is
checked before execution, not inferred from successful transfer. Quality now
has a real native provider-gated choice editor on both hosts (see `ttsQuality`
below), and three separate facts apply to it: an absent stored override
remains nil, not a resolved value; HIGH is the editor's own canonical
preference/metadata default shown when nothing is stored, a distinct fact
from execution; and which quality value is actually executable depends on
the selected provider's own tiers. Preserving an unrecognised stored string
is forward compatibility, not proof that string is executable. Pronunciation
remains unimplemented and opaque here.
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
| Automation | Windows per-user named pipe; Linux `LinuxAutomation.swift`, shared Host commands and `SpeakLinuxAutomation` private Unix socket/`speak` journey (source-only, native qualification pending); `--toggle` remains |

Paths named relative to `Sources` in a cell inherit the preceding `Sources/`
prefix. Missing rows cite the canonical Mac definition above and their native
replacement/nearest implemented surface; they do not assert hidden support.

| Mac key | Windows / Linux outcome | Evidence or remaining work |
|---|---|---|
| appearance | Equivalent / Equivalent | General; system/light/dark native schemes |
| visualDensity | Wired; native acceptance pending / Wired; native acceptance pending | General Normal/Compact choice; strict shared configuration, JSON transfer and native page/card/sidebar spacing |
| transcriptionMode | Equivalent / Equivalent | Models; Remote Batch/Live and Local batch |
| liveTranscriptionModel | Partial / Partial | Models; implemented transport routes only; Apple Speech and unavailable providers are not substitutes |
| batchTranscriptionModel | Equivalent / Equivalent | Models; independent remembered batch model |
| localTranscriptionModel | Partial / Partial | Models; whisper.cpp catalogue, not all Mac inference runtimes/imports |
| localTranscriptionMode | Partial / Partial | Local batch only; local streaming absent |
| localStreamingModelSource | Missing / Missing | No native local streaming source editor/runtime |
| postProcessingEnabled | Equivalent / Equivalent | `DesktopHostPostProcessing.swift`; desktop default remains disabled. Source proposal adds explicit local rules opt-in without credential access; remote remains opt-in |
| postProcessingModel | Partial / Partial | Shared remote catalogue plus canonical built-in Local Cleanup in the source proposal; downloaded local LLMs and Apple Foundation Models remain unavailable |
| postProcessingTemperature | Wired / Wired | Config; range 0...1, OpenRouter request |
| postProcessingOutputLanguage | Wired / Wired | Config; remote cleanup system prompt; built-in rules explicitly ignore it |
| postProcessingIncludeLexiconDirectives | Source wired / Source wired | Native post-processing switch, Mac default true, options/session snapshot and strict transfer; excludes saved directives from remote requests when false |
| postProcessingIncludeContextTags | Source wired / Source wired | Native post-processing switch, Mac default true, options/session snapshot and strict transfer; excludes saved context tags from remote requests when false |
| textOutputMethod | Equivalent / Partial | Output; Windows Smart/direct/clipboard; Linux paste/clipboard, no direct accessibility insertion |
| restoreClipboard | Equivalent / Partial | Output; Windows restoration; Linux X11 owned plain-text restoration only. Wayland capability-gates the control, retains its saved X11 choice and leaves pasted text on the clipboard |
| appSwitchDelivery | Source wired, native qualification pending / Source wired with explicit targeting gaps | Shared Mac policy/type and native chooser; sole native-options persistence, strict transfer and recording snapshots. Windows safely addressable native fields support original-background and guarded delivery-time retarget; Linux switched destinations copy only until a separately safe field route exists. See application-switch delivery above. |
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
| deepgramStopGracePeriod | Equivalent migration / Equivalent migration | Valid legacy value initializes absent liveStopGracePeriod; canonical value, including zero, wins; legacy retained for downgrade |
| liveStopGracePeriod | Partial / Partial | Config; AssemblyAI/Cartesia only; range 0...2 s |
| preferredAudioInputUID | Equivalent / Equivalent | Native device ID with missing-device warning, never Apple UID translation |
| defaultTTSVoice | Source wired; qualification pending / Same | Canonical Mac scalar transfer updates the sole native `modelID`/`voiceID` selection; a desktop-only companion preserves advanced models. Absent keys preserve legacy behavior; unsupported raw intent survives restart/export and refuses speech and selected-key access rather than taking a fallback. Native catalogue/account choices replace it only after persistence succeeds. Catalogue membership is not host/provider acceptance. |
| ttsLanguage | Wired candidate; qualification pending / Same | Native preferences project the sole Voice language; Soniox completed-audio requests capture it independently of dictation profiles. Other providers are not newly language-enabled |
| sonioxTTSRegion | Wired candidate; qualification pending / Same | Canonical US/EU/JP native choices, sole-model transfer/restart, regional-key/context fences and bounded Soniox v2 completed WAV. Unknown regions remain stored but cannot send a key; no host fallback or portable realtime TTS |
| ttsSpeed | Source wired; qualification pending / Same | Dedicated native Voice synthesis controls use the canonical selected-route speed limits; sole Voice-model apply/restart/transfer and immutable synthesis options feed Read aloud/Generate/fresh Export. Unsupported stored controls are retained and refused before credential access; Normal controls resets them explicitly. Native/provider acceptance remains unqualified. |
| ttsPitch | Source wired; qualification pending / Same | Both native Voice synthesis dialogs edit whole semitones from -12 to 12. Canonical route flags enable pitch only for Azure Neural; unsupported values remain stored and fail before credentials rather than being ignored. Shared validation and sole-model transfer remain; native/provider acceptance is not established. |
| ttsQuality | Source wired; qualification pending / Source wired; qualification pending | Native provider-gated `Speech quality (provider-specific)` choice editor (`VoiceSynthesisPreference.swift:4,28-30`, `WindowsConfiguration.swift`, `LinuxConfiguration.swift`), disabled when the selected provider has no quality tiers; transfer/apply confirmed above. Absent stored override remains nil; HIGH is the editor's own canonical default metadata shown when nothing is stored, a separate fact from which value is actually executable for the selected provider; native/provider qualification on this exact head is not separately captured here |
| ttsOutputFormat | Source wired; qualification pending / Same | Canonical MP3/M4A/WAV catalogue, native format picker, sole Voice-model transfer/restart and captured Generate/fresh Export format. Exact encoded bytes are retained for archive/export; playback uses decoded WAV. Exact-rate and installed-codec gaps remain; portable/build and native/runtime qualification are still required. Read aloud keeps its independent native PCM path. See desktop-voice-sources.md. |
| ttsAutoPlay | Source wired; qualification pending / Same | Native generated-voice controls and strict boolean transfer update the sole Voice model. Generate captures the option and conditionally starts its owned playback after successful synthesis; disabling it retains the generated result for explicit playback/export. Read aloud remains a separate explicit action. Source wiring is not native/provider/installed acceptance. |
| ttsSaveToDirectory | Source wired; qualification pending / Same | Strict boolean projects to the sole Voice model. Generated results archive their captured MP3/M4A/WAV container bytes in the actual owned recordings directory, never an imported foreign path. Retained exports reuse those exact bytes; source wiring is not native/runtime or installed-package qualification. |
| ttsUseSSML | Source wired; qualification pending / Same | Both native synthesis dialogs expose provider-gated SSML with explicit Normal controls reset. Azure Neural/MAI use the shared bounded SSML preflight and request builder; unsupported routes, conflicting full-document prosody and invalid controls fail before credentials. Canonical transfer and the selected-text markup helper are wired; native/provider acceptance remains unqualified. |
| ttsFavoriteVoices | Source wired; qualification pending / Source wired; qualification pending | Native voice picker ranks and toggles favorites in Read aloud (`DesktopHostVoiceFavorites.swift`, `WindowsReadAloud.swift:30-41`, `LinuxReadAloud.swift:117-125`); transfer/apply confirmed above. No separate standalone favourites-management page; native/provider qualification on this exact head is not separately captured here |
| ttsPronunciationDictionary | Source wired; qualification pending / Same | Strict word-to-text transfer/restart preserves the raw map; only keys seed AssemblyAI recognition using the shared Mac policy, never phonetic values or TTS replacements. A separate native Legacy word dictionary editor supports stale-safe CRUD without altering the modern store or Voice rendering pipeline. Modern literal-word recognition seeding is separately wired above. |
| historyFlushInterval | Missing selector / Missing selector | History is durable per operation, not configurable timed flush |
| silenceDetectionEnabled | Executable; qualification pending / Same | Native switch; initial quiet and configured silence stop the existing manual recording/finalization pipeline |
| handsFreeDictationEnabled | Sound-activation replacement; qualification pending / Same | Fresh frozen target per utterance, record-bound acknowledged output; unconfirmed paste stops, Wayland requires clipboard-only; profile/model still fixed per run; not Apple's classifier |
| silenceThreshold | Executable; qualification pending / Same | Canonical range/default and Mac PCM meter; native editor feeds manual silence and sound activation |
| silenceDuration | Executable; qualification pending / Same | Canonical hold/range feeds manual auto-stop and hands-free debounce; existing recording tail is retained |
| connectionPreWarmingEnabled | Partial / Partial (source only; NOT_RUN) | Canonical intent round-trips. Separate native session approval allows a credential-free HEAD on the shared OpenRouter pool with a 5-second cancellation budget, only at idle after acknowledged ordinary capture in the current process/configuration and its real cleanup credential check. No probe before successful capture after restart; approval and capture evidence are transient. Completed-request remote cleanup only; native live WinHTTP/NIO and streaming cleanup's owned delegate sessions cannot reuse this pool. Owned/hands-free capture does not provide this witness. Existing device/absence notifications invalidate readiness; no new network/sleep monitor, idle timer/retry or guaranteed latency improvement. |
| audioPreWarmingEnabled | Missing / Missing | Native capture opened on demand, no capture prewarming preference |
| warmMicrophoneOnKeyPress | Missing / Missing | No speculative microphone-open preference |
| postProcessingStreamingEnabled | Source wired; qualification pending / Same | Native preferences and sole Options authority feed bounded incremental remote SSE cleanup of finished text, with captured inputs, coalesced preview tickets and final-only History/output. Legacy desktop absence stays one-shot; local routes remain completed-only/offline. This is not external streaming insertion or native/provider qualification. |
| hudSizePreference | Wired / Partial | Config + shared `HUDExpansionPreference`; native chooser and full-card expansion on Windows/X11; retained but hidden on Wayland |
| showLiveTranscriptInHUD | Wired / Partial | Config + Windows/X11 HUD; Wayland has no live overlay, so the control is hidden; transcript remains in main window |
| showCompactHUD | Wired / Partial | Config + native compact Windows/X11 renderer; hidden on Wayland, where notifications are compositor-owned |
| shortenErrorDisplay | Wired / Partial | Config + HUD; native Windows/X11 timer; Wayland notification lifetime is desktop-owned |
| showSidebarShortcutHints | Wired; native acceptance pending / Wired; native acceptance pending | General strict Boolean/default true; shared Ctrl-number bindings, live sidebar/accessibility hints; hints off preserves navigation. This separate source-only candidate adds Linux Profiles with Ctrl+9; native acceptance remains pending. |
| speedMode | Source only / Source only | Native Instant/Auto-Clean choice and per-recording engine; supported live routes only; validation NOT_RUN |
| livePolishModel | Source only / Source only | Captured explicit/profile/default model through existing OpenRouter/downloaded-LLM adapters; no rules-as-LLM fallback; NOT_RUN |
| livePolishDebounceMs | Source only / Source only | Canonical 500 ms default; injected scheduler, whole-millisecond validation; NOT_RUN |
| livePolishMinDeltaChars | Source only / Source only | Canonical 20-character default; edits/retractions invalidate stale output independently of growth; NOT_RUN |
| livePolishTailWindowChars | Preserved, inactive / Preserved, inactive | Mac stores but does not consume it in LivePolishManager; full-transcript cleaning, no inert native control |
| skipPostProcessingWithLivePolish | Source only / Source only | Skips ordinary processing only after successful authoritative-final cleanup; raw/failure metadata retained; NOT_RUN |
| voiceCommandsEnabled | Implemented, native acceptance pending / Implemented, native acceptance pending | General toggle; canonical expansion before vocabulary and optional polish |
| streamingInsertionEnabled | Missing / Missing | Final transcript insertion only |
| clipboardInsertionTriggers | Implemented, native acceptance pending / Implemented, native acceptance pending | General trigger entry; bounded native snapshot, canonical matching, no History re-expansion |
| enableSendToMac | Partial / Partial | iCloud web History sync is not Send-to-Mac transport/pairing |
| enableAutomationServer | Equivalent / Source wired, unqualified | Automation; Windows per-user named pipe unchanged. Linux native opt-in starts a bounded same-user Unix socket and `speak`; imported/legacy true preserves intent but never grants device-local approval. False revokes. No native/runtime qualification claimed. |
| pasteRemoteTranscriptsAtCursor | Missing / Missing | No remote transcript delivery preference |
| autoCorrectionsEnabled | Source wired, unqualified / Separate opt-in observational source, unqualified | Canonical true default is not consent. Windows retains its acknowledged native Edit/UIA Value route and session approval. Linux observation is OFF until its distinct disclosed local in-app session action; generic approval and imports cannot authorize it. Only an admitted ordinary AT-SPI field with a bounded observational span qualifies. Paste/clipboard never do. App-origin changes can also be learned. Manual candidate actions remain available when learning is off. NOT_RUN |
| autoCorrectionsPromotionThreshold | Source wired, unqualified / Source wired for opt-in observation, unqualified | Canonical Mac default 2 and integral 2...10 validation; captured per observation and passed to the shared domain with its persistence/rollback behavior. Linux preferences are editable but cannot activate sampling or grant consent. NOT_RUN |
| recordingSoundsEnabled | Native qualified / Native qualified | General + owned native channel; normal readiness/finish cues only; installed-package acceptance pending |
| recordingSoundProfile | Native qualified / Native qualified | Canonical four profiles + owned preload replacement and explicit previews; all eight production AACs decoded on Windows/Linux |
| recordingSoundVolume | Native qualified / Native qualified | Strict 0...1 field + Mac volume-squared gain; native tests and queue bounds passed; installed-package acceptance pending |
| assemblyAIKeyterms | Wired / Wired | Config + options-bearing live factory; provider enforces vocabulary bounds |
| transcriptionKeywords | Route-dependent / Route-dependent | Shared immutable recording snapshot, batch/import/retry and live delivery below; unsupported routes report a limitation |
| transcriptionKeywordsLastReconciled | Wired / Wired | Shared `TranscriptionKeywordPolicy` + Config; unchanged-mirror/deliberate-clear reconciliation, durable last mirror |
| recoveredTranscriptionKeywords | Wired / Wired | Config; native selected-edit recovery with stale-selection and atomic-write guards |
| assemblyAIIgnoredPronunciationTerms | Source wired; qualification pending / Same | Strict text-array transfer/restart suppresses modern and legacy pronunciation recognition seeds; explicit native keyword clear/reselection updates suppression without changing unrelated entries. Automatic displayed hints are not persisted as explicit keywords; no separate raw suppression-list editor. |
| modulateSpeakerDiarization | Live/batch source wired; unqualified / Same | Native default/on/off choice retains absent batch-on/live-off defaults; strict booleans snapshot into recording, import/retry, automation and comparison requests. Native/provider acceptance pending. |
| modulateEmotionSignal | Live/batch source wired; unqualified / Same | Native default/on/off choice, strict transfer/restart and captured live/batch provider flags; absent stays off. Native/provider acceptance pending. |
| modulateAccentSignal | Live/batch source wired; unqualified / Same | Native default/on/off choice, strict transfer/restart and captured live/batch provider flags; absent stays off. Native/provider acceptance pending. |
| modulatePIIPhiTagging | Live/batch source wired; unqualified / Same | Native default/on/off choice, strict transfer/restart and captured live/batch provider flags; absent stays off. Native/provider acceptance pending. |
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
shared ordering/session snapshots; this separate source-only candidate adds
the GTK editor and actual recording selection described above. Apple bundle-ID matchers are preserved but
not silently converted to executable paths.

The Mac's 12 `SettingsTab` destinations are General, Transcription,
Post-processing, Profiles, Voice Output, Pronunciation, API Keys, Keyboard,
Permissions, Compare Models, Data & Migration and About
(`Sources/SpeakApp/Views/Settings/SettingsTab.swift:3-15`). Native desktops expose
General/Transcription/Post-processing/Voice Output/Keyboard/About and iCloud sync;
Windows also exposes Profiles; the GTK Profiles destination is added by this
unqualified source-only candidate. Provider keys are embedded under Transcription,
not a complete API Keys management page. Comparison is implemented as a
separate native window outside this `SettingsTab` list — live/file multi-model
capture, blind judging/ranking, playback and scoreboard export
(`DesktopHostComparison.swift`, `WindowsComparison.swift`,
`LinuxComparison.swift`'s `jsti_comparison_present`) — not a missing journey;
it has portable test coverage but no native device/CI acceptance evidence
captured in this document. No dedicated `SettingsTab`-equivalent Pronunciation or
Corrections page exists on native desktops; Desktop's separate `DesktopVocabulary`/
`WindowsVocabulary` editor window already provides an equivalent lexicon, pronunciation.json
CRUD and auto-correction candidate review journey, reused from Read aloud/Generate above — not
a missing journey, just not a `SettingsTab` destination. Permission troubleshooting/remediation
and full archive migration remain missing journeys; Linux profile editing still needs
compilation and native acceptance. Strict acknowledged mutation attribution remains an **open Linux
parity gap**: neither paste keys nor a top-level window supplies an editable-span receipt.
The separate Linux source-only observational route is described below; it does not close that
acknowledgment gap. The Windows source-only learning
path uses acknowledged native Edit caret identity or confirmed whole-field UIA Value replacement,
then retains and samples only that UIA text range with bounded surrounding guards. UIA interfaces
are created/read/released on the existing COM worker, never on Swift tasks. Password,
unknown-sensitive, noneditable, oversized and ambiguous ranges are refused. Clipboard and
unconfirmed/paste-only delivery are not observed. A new recording, output replacement, disable,
stop-learning or close cancels/fences pending samples; process/window/control/focus changes and
surrounding-context edits invalidate the native lease. No focus probe is added to recording start,
and no captured text is logged. Imported preferences do not grant the in-memory session approval.
Mac IPA/phoneme/SSML parity and native learning qualification remain open.

The learning candidate is authored on exact `f6f2ac90` only. Its focused
`AutoCorrectionLearningPolicyTests`, added `AutoCorrectionDomainTests`,
`DesktopCorrectionObservationTests` and `DesktopHostCorrectionLearningTests`, native Windows
text-output fixture additions and GTK read-only-field assertion are **NOT_RUN** here: this host
has no Swift toolchain, and WSL/native/UI execution is not authorized. No prior component receipt,
provider test or other source tree qualifies this learning candidate.

The bounded Linux successor is based on exact `b05a2d41`, without changing the earlier frozen
learning packets. It adds `observedInsertion` and `observationalATSPISpan`, distinct from Windows
`confirmedInsertion`/acknowledged provenance. Observed delivery does not permit automatic
hands-free resume. Linux's Allow dialog explains that app-origin formatting/changes can also
be learned; it issues a generation-bound local one-use offer. Both Allow and Stop carry
that immutable native generation through queued Host actions. An older queued Allow cannot
consume a newer offer, nor can an older queued Stop revoke it. Tokenless, imported,
malformed and replayed grants cannot authorize observation. Stop remains actionable while
another editor action is pending. Editor destruction revokes only its own generation, so
a delayed old editor cannot revoke a reopened editor's offer.
Consent is memory-only and defaults OFF. Stop revokes native capability immediately, before
queued Host work; disabling learning and closing revoke it too. No OS accessibility property
is written and no bus/helper/screen reader is autolaunched. Cached availability is shown on
refresh; unsupported desktop/toolkit/sandbox targets keep ordinary unconfirmed paste behavior.
Wayland is not blanket-excluded: availability depends on the actual AT-SPI field, not X11 IDs.

The integrated output job admits an original-field observational lease only for legacy
(`appSwitchDelivery == nil`) automatic paste. Every explicit app-switch policy and clipboard-only
output refuse that lease before dispatch: they cannot observe or learn from the original
field, nor use its consent to redirect output. Explicit same-foreground X11 delivery remains an unconfirmed
guarded paste; unsupported switched/background X11 and explicit Wayland intent remain recovery
copies. Legacy Wayland may still use a separately consented AT-SPI field without a remote-input
portal; a copy-only fallback plan alone does not revoke that capability. The old three- and
five-argument target initializers and two-argument output-job initializer remain available.
Only recording-target capture attaches the observational lease; delivery-time X11 identity/focus
checks retain their metadata-only capture and do not acquire a new field capability.
Five additional authored integration cases cover these interactions and initializer references;
they are **NOT_RUN**, not native acceptance evidence.

Before registering events, bounded metadata introspection verifies the installed registry's
app-scoped `RegisterEvent(s, as, s)` and either historical `DeregisterEvent(s)` or current
`DeregisterEvent(s, s)` cleanup contract. Unknown contracts fail closed before registration.
Cleanup uses the negotiated signature on the private worker with finite 300 ms calls;
failure stops observation, reports a non-sensitive cleanup failure and closes the private
connection rather than silently retaining subscriptions. Historical prefix cleanup restores
only minimal focus metadata discovery when needed, not a global text listener.

After consent, a private in-process GIO worker listens only to essential focus metadata for
discovery. It admits a known nonpassword Text/EditableText control in another process with
an application/top-level parent chain, unique bus owner, connection epoch and local focus
generation. Recording target capture only takes an already-admitted identity, never a late
focus reconstruction; focus must change to a supported field after consent. Native mutation,
verification and readback run off UI/audio/start queues with finite RPC/request budgets.
Insertion is collapsed-caret/no-selection only: `InsertText` length uses UTF-8 BYTES while
offsets and event lengths use native CHARACTERS (not Swift graphemes or UTF-16).
Known-safe role/state is rechecked before bounded text reads. A matching insertion event,
pre/post text/count/caret and surrounding guards qualify only observational evidence.
FALSE, timeout, cancellation, mismatched/absent events or ambiguity after dispatch yield an
explicit indeterminate failure without retry, clipboard fallback or learning.

Standard AT-SPI has no transaction ID, retained TextRange or atomic compare-and-insert.
The native regression documents the indistinguishable case where an application prefill
emits the matching event and a subsequent no-op accessibility insertion still returns TRUE.
This is intentionally accepted only as disclosed observation, never acknowledged causality.
Subsequent events are scoped to that object; app-scoped registration never grants a global
text listener. Strict interior edits fold into a bounded character-offset span; its final
text must equal the folded events and retain unchanged bounded guards. Unknown/malformed,
missing-visible, reset, out-of-span or ambiguous-boundary edits invalidate it, as do privacy,
parent, focus, owner, connection and lifetime changes. There is no fabricated server revision
or claim that undetectable dropped events are detectable. The adapter is deliberately
conservative: whole-span/boundary replacement and unsupported toolkit events are skipped.
Queued callbacks retain native lifetimes and become inert on cancellation. No raw field text
is logged. Native ownership remains checked through shared domain admission, not just the
readback reply. After a lease ends, the worker may revalidate the same known control's
metadata for a fresh lease; it never reuses its text or discovers a field on recording start.
Candidate extraction/promotion still uses the existing shared domain and timing.

Authored successor checks are `LinuxObservationalInsertionTests`,
`DesktopHostObservationalLearningTests` and the no-bus/no-UI native
`jsti_atspi_contract_self_test` invoked by the former. They cover delivery provenance,
no fallback after uncertain dispatch, consent/import separation, actual Host output and
promotion, revoked local offers, held-queue old-Allow/old-Stop/new-offer ordering,
tokenless/malformed/replayed actions, pending native Stop availability, both registry cleanup
schemas and unknown contracts, invalidation at read completion, held-task Stop/close,
state bitmaps/privacy, Unicode units, event folding,
ambiguity and late/owner/connection fences. All are **NOT_RUN**: this assignment authorizes
source inspection/handoff only, not a compiler, test runner, native/UI/bus probe or provider
call. Toolkit/X11/Wayland/runtime qualification remains open and requires reviewed integration.

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
