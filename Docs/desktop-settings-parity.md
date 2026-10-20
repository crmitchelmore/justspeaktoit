# Desktop settings coverage

This is a settings slice, **not full Windows/Linux feature parity**. Baseline:
macOS `AppSettings.DefaultsKey` aliases the shared 91-key
`ApplicationPreferenceKey` (`Sources/SpeakCore/ApplicationPreferenceKey.swift`),
plus preferences and collections
outside that enum. Track remaining product acceptance in #1157.

## Core Journey qualification cache (source only)

Automatic #1229 head `a729af1e` restored its exact Swift cache successfully,
but the test-product build exceeded its 900-second budget before runtime tests
started (job `118272169107`, elapsed `900.581`, exit `124`). Debug produces that
cache with code coverage enabled; Core Journey previously requested plain
build/test flags. Both Swift stage commands now request `--enable-code-coverage`
to avoid invalidating the restored graph solely through instrumentation.
The prepared-product receipt already includes the full build command, so
products prepared with the old flags cannot pass runtime admission.

The full build graph, all 15 required suites, 900-second preparation budget,
480-second Swift runtime budget and runner approval guards are unchanged.
Command and workflow contracts now enforce matching instrumentation and cache
keys. These source changes are NOT_RUN locally; an automatic run must still
show whether alignment is sufficient for the changed-source build to fit.

The later unaligned `f1852488` run passed Core Journey automatically
(job `118306904661`): preparation took 657 seconds and runtime 33 seconds.
The earlier timeout was therefore not deterministic; the coverage mismatch
remains an unnecessary invalidation, not a proven sole cause. Qualification
of the aligned commands and later feature descendants is separate.

The later `1667ee83` tooling job `118642531254` passed SwiftLint with zero
violations but its cancellation fixture timed out. Its readiness substring
also matched the flushed command header before the compiler was launched.
The fixture now requires exact standalone compiler and descendant output
lines, plus a marker from the owned process's `wait()` call after the gate
assigns its handle. A negative contract rejects the command header and an
unowned process. Production cancellation behavior, build/runtime budgets and
the existing leak observation window are unchanged. This fixture repair is
NOT_RUN locally and still needs automatic qualification.

## Shared provider credential write ownership (source only; NOT_RUN)

The API Keys, Transcription and Post-processing editors now share an owned
off-actor writer for native vault calls and the existing saved-by-hand sync
hook. The Host actor remains available while storage is blocked. One writer
slot excludes competing edits, including Voice Output key writes, and stays
owned until the actual storage call returns, even if its request is cancelled.
Closing cancels that worker, accounts for it in the normal shutdown grace and
does not claim that cancelling an already-started vault call rolls it back.
Completed native writes still update the tracked identifier index; failures
remain unconfirmed and never echo arbitrary native error contents.

Late API Keys completion after cancellation or closing asks the user to check
saved state instead of announcing success. Cancelled per-feature saves do not
continue applying post-processing settings. Four regressions cover blocked
native and saved-by-hand writes, cross-editor exclusion, bounded Host close
and partial-write error redaction. They are authored but NOT_RUN locally.
Readiness is signalled from inside the actual vault call, not inferred from
elapsed time. The new fixtures allow ten seconds for native entry and use a
thirty-second emergency release; their Host shutdown grace remains forty
milliseconds and must return while the vault gate is still blocked. Existing
Voice fixture watchdog defaults are unchanged.
Both native Transcription callbacks now queue only admission into a separately
owned editor task. Key-bearing remote Post-processing Apply uses that same
admission path and republishes native controls only on live completion.
Keyless Apply still completes in settings order before the next snapshot.
Pending edits hold the normal Host/native busy state, so Record cannot overtake
them. Later Applies keep their event order in the separately owned edit FIFO,
with at most eight pending edits; excess admission is explicitly refused.
The final busy-state reset retains the actual save success or failure message.
After settings drain, both hosts stop editor admission and cancel its work
before clearing native callbacks or services; close also cancels the owner.
Storage that has already started may still finish, but cancelled Apply cannot
continue changing post-processing settings or republish a closed editor.
Six additional queue/owner regressions cover blocked Transcription and
Post-processing drains, keyless ordering, ordered live completion, later Apply,
bounded overflow and permanent shutdown refusal. These native wiring and test changes remain
NOT_RUN locally; this is not yet automatic qualification of the drain contract.

## Linux Permissions destination (native CI qualified; physical acceptance open)

About's **Permissions** button, Open Permissions action (run 10/event 118)
and Troubleshooting's permission finding open a distinct modeless libadwaita
window. It presents shared permission kinds with Linux-specific guidance for
microphone, insertion, command automation, notifications and startup, plus the
actual dictation listener hint. Check again reads current saved app settings
in event order, without opening devices, contacting a provider, probing another
app's text, launching a system settings process or requesting a portal grant.
General and Keyboard remediation buttons open the existing native controls.

Detected X11/Wayland sessions and enumerated input devices never become an
Allowed status. Clipboard-only output does not need keyboard injection.
Microphone, notification and automatic-insertion permission grants remain
unknown where Linux exposes no authoritative query. Observed microphone
warnings remain visible, Flatpak audio restrictions and GNOME/KDE privacy
guidance are explicit, and a saved startup request is not presented as an OS
grant. Actual local automation approval is the one granted state this passive
report can establish. Desktop privacy changes remain user actions; Wayland's
existing explicit paste workflow requests RemoteDesktop access when needed.

Revision fencing ignores late reports after Check again or close/reopen.
Four pure Linux presentation tests and native lifecycle/invalid-row/dispatch
fixtures were NOT_RUN locally. Automatic `1667ee83` qualification passed native
Windows (job `118642699896`) and Linux desktop (job `118642912114`), plus Debug,
Core Journey, Fixture UI and API compatibility. This is a usable permission recovery
destination, not evidence that capture, insertion or desktop permissions have
been exercised on a physical system.

## Correction learning preferences (source only)

GTK now presents the canonical learning enable/threshold fields directly above
the Corrections editor instead of burying them in General. Windows Corrections
has a Learning preferences button that opens the existing Corrections preference
group. Both reuse the existing revision-aware preference authority and save
path; there is no second settings store or implicit session approval.
Linux observational learning still requires separate local session consent.
Windows Stop learning remains enabled while candidate work is pending; Allow
and mutations stay disabled. Stop follows the existing ordered settings queue,
with explicit waiting-for-confirmation feedback rather than claiming revocation
before the Host has processed it.

Authored native fixtures check GTK row ancestry, Windows page scope and initial
Corrections group selection, and saving without losing hidden preference values.
Additional fixtures check pending native Stop availability and that Host Stop
revokes approval, cancels a held observation before readback, and prevents
further output from starting another observation without fresh approval.
These changes have not been executed locally; automatic native CI and actual
installed learning workflows remain required before claiming acceptance.

## Quick Voice action foundation (source only)

The shared Host has an action for Quick Voice slots 1 through 3, using the
Mac's raw ordered favourite list. Unknown or unavailable entries do not shift
later favourites into a different slot, and duplicates remain preserved.
A compatible current model is preferred when several models expose the same
voice. Selection uses the existing Voice Output persistence and error path;
it does not start synthesis or perform discovery or credential lookups.

Authored Host regressions cover raw slots, duplicate/unavailable entries,
model retention, restart, credential isolation, missing/invalid slots and refused persistence.
These checks are **NOT_RUN** locally. Windows maps the Quick Voice 1-3 action
shortcuts to this action (`JSTI_ACTION_RUN_QUICK_VOICE_1`-`3` emit
`JSTI_EVENT_QUICK_VOICE` with the slot, queued on the settings queue; ignored
while Voice Output settings are locked). Linux now has source-wired window-local
Quick Voice 1-3 actions through the same Host, gated while recording or working;
global action registration and physical keyboard qualification remain open.

## Paste last History action foundation (source only)

The shared Host can explicitly deliver the most recent History item's processed
text (or its corrected/original fallback), using saved text-output settings and
the field captured by the native action. It ignores the active History search
and selected row without changing either. An empty newest item reports that
there is nothing to paste rather than silently substituting an older item.
Clipboard-only output does not require a captured field.

The action reuses the existing single owned output slot, cancellation and
shutdown path. It does not start correction observation or change the
recording HUD. Missing targets and delivery failures remain visible. Authored
Host regressions cover selection/search independence, processed/raw text,
clipboard-only output, empty newest entries, target/delivery errors, no
credential lookup and no observational readback even with local approval.
These checks are **NOT_RUN** locally. Windows maps the Paste Last History Item
action shortcut to it (`JSTI_ACTION_RUN_PASTE_LAST_HISTORY` emits
`JSTI_EVENT_PASTE_LAST_HISTORY`); the callback captures the focused field on the
UI thread before queueing the Host action, as the Record event does. Linux does
the same through window-local run 11/event 111. It captures the invocation target
before joining the settings queue, without acquiring the one-shot AT-SPI
observational target or starting correction learning. Native admission refuses
recording, work and an insensitive parent, but is independent of the History
page, selected row and speech controls. The saved output policy remains
authoritative: clipboard-only works without a field; paste requires a captured
target. X11 never substitutes a stale external window when this app has focus.
Wayland retains its documented delivery-time-focus portal and recovery-copy
policy; it does not acquire an anchored external-field guarantee.

Both hosts now bound History-paste admission **before target capture**: only one
request can wait in the settings queue. Further invocations report that paste is
pending rather than capturing and retaining more external targets. The Host checks
the request's one-second monotonic capture budget immediately before starting
output; an expired or shutdown-invalidated request reports refusal, never retries,
and releases its admission slot only when its queued consumer returns. Shutdown
invalidates this gate before draining settings. The existing separate output slot
still refuses overlapping output. This bounds delayed requests; it does not expand
X11/Wayland target guarantees or change ordinary Copy or recording output. Portable
burst/expiry/concurrent-admission tests and Host queued-expiry/cancellation tests
are authored but NOT_RUN locally, pending automatic native/portable qualification.

Linux now has **25 of 27 source-wired window-local actions**; selected-text speech,
voice editing and global action registration remain open. Mapping, native row
validation and busy/recording/parent/page-independent dispatch fixtures are
authored but NOT_RUN locally. They need automatic qualification. Clipboard
delivery alone is not evidence of external-field paste or global-shortcut parity.

Linux also exposes `--speak-clipboard`, `--paste-last-history`, `--stop-speech`,
`--pause-resume-speech` and `--quick-voice-1` / `--quick-voice-2` /
`--quick-voice-3` through the existing GApplication command-forwarding path.
Quick Voice selects a saved favorite without reading text or starting speech.
Stop reuses Playback Stop availability, including during other work, while the
other commands reuse their existing idle gates. The app must already be running:
cold invocations are refused, and forwarding never raises the app window.
Users can bind them in desktop keyboard settings; global action rows explain
this fallback without presenting the saved binding as registered. Different
action flags or unsupported options together are refused before dispatch. Busy,
recording, closing and modal-disabled states refuse commands according to those
existing action gates; distinct Quick Voice slots conflict before dispatch.
Command parser/dispatch fixtures are authored but NOT_RUN locally.
Legacy `--toggle` also receives pure preflight before model/controller/store
initialization: malformed options or conflicting actions are refused, while a
valid toggle retains its cold-launch/remote behavior. The native command handler
independently rejects unknown options for every action, including toggle.
The automatic desktop-check harness additionally enables 32 real child
command processes on its private bus with synthetic native event capture, bounded
waits, refusal diagnostics, hidden-window/page invariants and an empty isolated
data-directory requirement, including malformed toggle options with and without
a primary. This does not deliver a Host/provider/field action.
The cross-process fixture is also NOT_RUN locally; automatic qualification,
compositor/provider and external-field acceptance remain open.

## Linux shortcut listener lifetime (source only; NOT_RUN)

X11 registration now reads the actual modifier/key maps rather than ignoring
guessed Mod2/Mod5 lock bits. Only lock-only slots are ignored, across every
symbol level; AltGr/group-switch/mixed slots and explicitly required modifiers
remain significant. The listener owns the exact unique grab/ungrab variants and
checks event modifiers before admitting a press. No-display native fixtures
cover relocated ScrollLock, AltGr, mixed/unknown keys, explicit lock modifiers
and zero/all-eight-bit subset bounds. These are authored but NOT_RUN locally.
Runtime remapping/rebinding, safe multi-action registration and physical
keyboard/layout qualification remain open, not inferred from this repair.
An additional authored private-Xvfb integration sequence rejects an extra Shift,
then requires one press/release in each off/Caps/Caps+Num/Num/off lock state with
per-phase producer acknowledgements and exact event prefixes. Cleanup is
deferred and all waits are bounded. This is NOT_RUN locally; it covers only the
disposable server's default map, not AltGr or runtime layout changes.

The existing dictation listener now owns its startup and actual native cleanup,
not just flags set after registration returns. Stop permanently fences new
callback admission and result publication. An already-started X11 or portal
registration may still finish, but its late success is immediately closed and
cannot republish controls. Shutdown does not wait for a blocked startup dialog.
Callback preflight is not final admission: native target capture and the gesture
style's synchronous queue read stay outside the lifetime lock, then a bounded
settings/gesture enqueue is atomically admitted against stop. If stop wins during
preparation, no gesture or microphone-warmup task is submitted. Held-preparation
and racing-final-admission regressions are authored but NOT_RUN locally.
The native callback context stays alive through the actual stop call and holds
the window/controller only weakly. A settings read already in flight rechecks
the publication fence afterward.

Six authored portable regressions cover stop-before-start, single admission,
blocked startup and late cleanup, explicit failure hints, reentrant cleanup
outside the state lock, and racing stop/completion. These are NOT_RUN locally;
automatic portable/native qualification remains required. Existing X11/portal
binding protocols, dictation gestures and fallback commands are unchanged.
This closes a listener-lifetime prerequisite; multi-action global registration
and physical shortcut acceptance remain open.

## Troubleshooting (source only)

Windows About and the Open Troubleshooting action now open a distinct modeless
report, not an alias for Permissions. It checks the saved recording shortcut,
clipboard restoration, missing remote post-processing credentials and observed
Windows permission states. The configuration check inventory, wording, severity,
destinations and explicit fixes live in `SpeakCore/DesktopTroubleshooting.swift`;
macOS consumes that inventory while retaining its own permission and Fn guidance.
Linux About now opens a native GTK Troubleshooting report using the same
configuration policy. It retains the current shortcut listener's actual hint,
labels unknown sessions and startup portal unavailability, and explicitly avoids
inferring microphone or insertion permission from session detection. Clipboard
restoration is checked only where X11 supports it; Wayland does not offer an
inapplicable restoration fix. API-key findings navigate to Linux Post-processing,
where the relevant key is edited; shortcut findings open Keyboard.

The Linux report has selectable, wrapped details, keyboard/Escape support,
rechecking, explicit fixes and close/reopen revision fences. It is modeless during
review; a pending fix temporarily protects the parent settings from competing
edits. Cleanup credential checks and persisted fixes use one shared desktop-host
authority on Windows and Linux. Refreshing a fix does not rebuild unrelated
configuration editors, and Linux's cleanup switch refresh preserves unsaved
prompt/model drafts. Credential checks use the normal desktop keyring read path,
including any unlock it requires. Opening the report does not probe the microphone
or request microphone/desktop permission grants.

Five portable host regressions cover persisted cleanup fixes, prompt/model
preservation, newer credentials, stale settings, closed controllers and effective
clipboard policy. GTK smoke fixtures cover pending fixes, stale/late reports,
close/reopen, invalid commands, invalid UTF-8 and row bounds. These are authored
but **NOT_RUN** locally. The report's separate window-local Linux action mapping
is described below; global registration and native/provider/device acceptance
remain open.

The macOS projection distinguishes an absent or empty credential from a failed
Keychain read. Failed reads offer no Disable cleanup action. Explicit fixes
recheck the captured settings, and cleanup rechecks both the credential and the
model after its asynchronous read. Refused fixes show an error instead of changing
newer choices. The report refreshes when the selected model or saved credentials
change, and uses the shared action titles. Eight focused Mac regressions cover
credential states, changes during a fix, newly available keys and preservation of
the selected model and prompt; these are authored but **NOT_RUN** locally.

Findings have scrollable, read-only details, settings navigation, and explicit
Keep transcript or Disable cleanup actions where applicable. No fix runs on
opening or rechecking. Fixes use the existing settings authorities, refuse stale
choices and busy/closed controllers, and recheck a previously missing credential
before disabling cleanup. Unreadable credentials and unknown permissions are
reported as unknown/warnings, never assumed missing or granted. Refreshes,
close/reopen and fixes have revision fences so late results cannot enable stale
actions. The existing Permissions renderer is shared, with independent report
state, keyboard navigation, labelled controls and DPI-aware layout/font updates.
Successful fixes refresh the native settings controls from their persisted
authorities. A pending fix briefly fences concurrent settings dialogs; closing
the report releases that fence and rejects late presentation.

Four portable regressions cover the canonical inventory, local/disabled/keyed
processing, missing versus unreadable credentials, and explicit clipboard fixes.
Native controller fixtures cover stale fixes, refused writes, other-setting
preservation, credential changes, shutdown and restart. The window smoke fixture
checks the action entry, read-only details, pending-action gating, stale/closed
result refusal and invalid commands without applying real settings. These are
authored **NOT_RUN** checks; compilation, native UI and installed acceptance
remain required. Windows uses action-run 14 and About control 453, with no new
window event.

## Selected-text and clipboard speech shortcuts (source only)

Windows wires Speak Selected Text and Speak Clipboard through the existing
Read aloud task, saved Voice Output selection/options, pronunciation rendering,
credential policy, usage and native playback. They do not borrow the selected
History record. Both are eligible for global registration. This brings Windows
to **26 of 27 source-wired actions** with Troubleshooting below. Voice editing
adds the final source mapping described below; neither count proves shortcut parity.

Selected text uses a read-only target captured in the native callback. Its
existing bounded UI Automation worker starts a snapshot before the settings
queue hop, reads only selected TextPattern ranges, and verifies the retained
process/window/control, UIA identity, password status and focus revision.
Read-only text controls and the app's own controls are permitted. The target
cannot insert text or replace the clipboard. Empty selections, unavailable
providers, identity changes, oversized text and timeouts fail explicitly;
there is no whole-field, clipboard or simulated-Copy fallback. Up to 64
selected ranges are joined with newlines, with 200,000 UTF-16 units of native
staging and the canonical **100,000 Unicode-scalar** speech limit.
Empty ranges add no separator and consume no staging budget, including after
an exact-limit range; separators between nonempty ranges count toward the limit.
Native helper regressions cover both exact-limit shapes, trailing empty ranges,
separator overflow, oversize and embedded-NUL rejection without partial appends.
These additional regressions are authored but **NOT_RUN** locally.

Automatic qualification at `d7487015` stopped at fixture compilation: a
captured-source gate helper was nested inside a test, and a Windows SDK
identifier collided with the undersized-buffer fixture. Both are repaired in
source. They require a fresh composed-head run; neither repair is passing
execution evidence.

The shared source type has a distinct captured-selection constructor; the
ordinary constructor and native Voice message parser still refuse an
uncaptured external selection. Pronunciation replacement preserves this
provenance. Clipboard speech reuses the existing explicit native snapshot,
with at most one pending native clipboard reader. A stalled clipboard owner
cannot create an unbounded collection of native reader threads.

Source capture is owned by the speech task with the existing three-second
cancellable read gate. Stop, replacement, recording and shutdown release the
Host without waiting for an uncooperative source; late text cannot reach a
speech provider. Authored portable/Host regressions cover exact Unicode limits,
source/provenance preservation, clipboard effects, invalid text, replacement
and Stop/shutdown during an uncooperative capture. The native hidden-RichEdit
fixture covers read-only selection, no field/clipboard/keyboard mutation,
one-shot authority, password/focus/identity/cancellation refusals, exact native
limits, small buffers and a blocked provider. These checks are **NOT_RUN**
locally; automatic native/portable qualification and actual keyboard/app
acceptance remain required.

The Stop speech action delegates directly to the Host, without a page,
selected-History-row or History-button-enabled gate, so these independent
speech sources can also be stopped.

## Pull-request qualification (source only)

Product pull-request workflows now accept non-main base branches, including
stacked parity PRs. Main-only push triggers, product path filters, job
permissions and release gates are unchanged. An authored CI-contract regression
guards this coverage without using the privileged `pull_request_target` event;
it is **NOT_RUN** locally. Before this trigger repair, the composed parity PR
received policy checks but no Windows/Linux/macOS product qualification.

The held `2bbc95b5` source has completed automatic portable Linux qualification
(2,937 tests, 33 skipped, zero failures) and portable macOS qualification
(2,841 tests, 55 skipped, zero failures), including all five About methods and
the Stop-learning cancellation regression. Native Windows job `118172260830`
also passed its adapter, window creation/shutdown and local-transcription
checks. These results do not qualify the subsequently composed parity source.

## About and manual updates (source only)

Native About now shows the installed app's version/build when stamped,
configuration, source commit when present, and platform distribution. The
existing Windows staging metadata and self-contained bundle manifest are read
beside the executable; neither the working checkout's `VERSION` nor a Mac
release is used as the installed desktop version. Missing stamps are labelled
explicitly. Malformed or oversized metadata produces a visible recovery
notice, not a fabricated version or silent success.
The 4-MiB metadata bound also applies during file reads, not just to a pre-read
size snapshot: a file that grows or changes after that check cannot cause an
unbounded read. An authored portable regression accepts an exact-limit padded
JSON document and verifies overflow rejection after consuming only one byte
beyond the limit. This additional check is **NOT_RUN** locally.

Windows and Linux retain their native branded About layout and controls.
Six canonical links shared with the Mac lead to GitHub, issue reporting,
privacy, releases, feature requests and the MIT licence. GTK links reflow at
narrow widths; Win32 uses its existing themed keyboard-accessible buttons.
Browser-launch failures are surfaced. Building or opening About never fetches
release data, installs an updater, downloads code or changes an app.

Automatic native Linux job `118172561007` failed to compile source `2bbc95b5`
(synthetic merge `f7ef4c5558ff083f456d44d2aae12999f1c6e2bf`) because the
browser-failure callback referenced nonexistent `JSTI_EVENT_ERROR`. The repair
removes that invalid dispatch while retaining the warning log and visible
status message. This is a source repair, not a successful native qualification.

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

At `820799c4`, automatic Linux portable job `118155024145` completed 2,931
tests (33 skipped) with zero failures. Native Windows job `118155306947`
failed compilation at the pending-control identifier loop: its deduced
initializer list mixed the control enum with the integer expression
`field + 1`. The loop now uses `std::array<int, 3>` without changing which
controls are protected. Both jobs checked out synthetic merge `0f428229`
into `0b4ffd7`. This Windows source repair is **NOT_RUN** locally; the failed
Windows job remains failed evidence, and the Linux pass does not qualify
later About, Voice or Corrections changes.

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

The macOS Debug job `118222049873` aborted in the successful-finish History
control with `freed pointer was not the last allocation`; Release success does
not qualify that failure. The delivery path now cancels only the opposite
worker/timer, not its own producing task. Regression sources assert uncancelled
success, failure and timeout delivery, preserve cancellation and identity fencing
of a late provider, and repeat default-clock finish/result encoding 64 times.
These changes are **NOT_RUN** locally and are not a verified allocator-crash fix;
automatic macOS Debug qualification is still required.

The default sleeper is also constructed by a non-inlinable library-owned factory,
not an async closure literal in the public initializer's default argument.
[swiftlang/swift#92017](https://github.com/swiftlang/swift/issues/92017) reports
incompatible async frame copies emitted into library/client modules by that
default-argument construct; Debug can abort while Release succeeds. The factory
preserves the initializer signature, `Task.sleep(for:)`, injected clocks and
cancellation semantics without changing toolchains or excluding Debug tests.
Existing History controls and the new default-clock regressions remain required;
the matching upstream report is evidence for the mitigation, not local proof.

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
application: the archive UI saves, inspects and restores History text and app
profiles (see [Restore backup](#restore-backup-windows-source-only)), but never
applies settings from a backup.

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

## App shell, recordings folder and analytics (source only)

`ShellPreference.fields` (`Sources/SpeakCore/DesktopShellPreference.swift`)
adds `appVisibility`, `compactStatusBarIcon` and `analyticsEnabled` to General
with the Mac keys, defaults and strict values, so save, restart and portable
JSON import/export round-trip them. `appVisibility` reuses the Mac's stored
cases with native labels: `both` is **Taskbar and notification area**,
`menuBarOnly` **Notification area only** and `dockOnly` **Taskbar only**.
`showStatusBarIconInDockOnly`, `paidAccessRoutingEnabled` and
`recordingsDirectory` stay opaque Apple-only keys: imports retain them for the
Mac and never execute them.

- **Windows app visibility** applies before the window opens and live on save
  or import. Notification area only gives the window a hidden tool-window owner
  (`GWLP_HWNDPARENT`), so it has no taskbar button; close and minimise hide it
  to the notification area, the icon or **Open** brings it back, a login launch
  stays there and **Quit** exits. It also leaves Alt+Tab while hidden, and
  reassigning the owner is a documented but discouraged Win32 pattern. If the
  notification area is unavailable (Explorer not ready) the window keeps its
  taskbar button and is never stranded. Taskbar only removes the icon.
- **Compact icon** (Windows) keeps the brand icon and recording dot but drops
  recording state from the tooltip and the totals line from the menu.
- **Linux** stores, shows and transfers both shell choices but does not apply
  them: GTK 4 has no portable tray or taskbar-hiding API, so the capability rule
  is persistence only until a StatusNotifier host exists.
- **Analytics**: Windows and Linux send no analytics or crash reports, so the
  switch has nothing to gate. It is stored and transferred so a Mac import keeps
  its choice; absent is never treated as consent.
- **Paid-access routing and Dock-only icon** have no desktop journey (desktop
  providers are bring-your-own-key and there is no Dock); both are preserved
  only.

`recordingsDirectory` itself is never executed: a Mac path in an import cannot
authorise a folder. A separate, device-local choice builds on SpeakDesktop's
verified recording locations (`DesktopRecordingLocations`, held captures and the
append-only private registry beside History):

- At startup the host reopens an existing private namespace on a cancellable
  worker; it never creates one. Only an explicit local choice initialises it and
  authorises the folder, which must be absolute and outside the app's data
  folder. The verified choice is kept in `recording-location.json` in the app
  data folder, never in portable settings, and is restored only when its
  registration still matches.
- New dictation and live recordings are written through a held capture in the
  chosen folder. If that fails, the recording goes to History with a note.
  **Use default** returns new recordings to History. Nothing is ever moved or
  deleted, and audio already in a chosen folder stays playable.
- Open folder reveals the chosen folder, otherwise History.
- Linux (Glibc) offers it in Housekeeping (**Choose…** with the GTK 4.10 folder
  dialog, and **Use default**). Windows keeps
  `WindowsRecordingRegistry.factory`'s `identityUnavailable` fence and reports
  that choosing a folder is not yet available, so recordings stay in History.
  Enabling it needs the Swift identity and restart integration for the native
  registry (keeping competing-open exclusion until close) plus a qualified
  held-capture writer, then a Windows folder picker.
- Not yet covered: recovering interrupted recordings from a chosen folder, deleting
  History items or cleaning audio there (refused, audio retained), and owned-capture
  startup, file import and comparison samples, which still write to History.

Portable tests cover the shared fields, one-time activation and foreign History
refusal. None of this has native, Linux or Windows acceptance yet.
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
Comparison results remain raw and never read the clipboard. A microphone
recording (including each hands-free utterance) freezes the enabled switch and
custom phrases at Record with its other provider inputs, so settings edited
while it records or finishes apply only to later recordings; a recording made
without stored preferences keeps the canonical defaults. Imports and retries
have no recording policy and use the current settings.

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

## Local canonical archive projection candidate

This bounded bridge is a **read-only partial projection**, not a full backup,
import transaction, native control change or declaration of 91 executable
preferences. It was composed on integration base `78ad44e8` and later
cherry-picked onto the parity integration head, where it was adapted to the
head's native post-processing, Voice and app-switch authorities; its
qualification must not borrow the earlier native or Apple receipts below.
Publication requires parent review.

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
sources are `DesktopHostSettingsArchive.swift` (with presence hooks in
`DesktopHostController.swift`), `DesktopHostPreferenceArchive.swift`,
`DesktopHostNativePreferenceProjection.swift`, `WindowsPreferenceArchive.swift`
and `LinuxPreferenceArchive.swift`; Mac wire names are established by
`AppSettings.swift` and the shared application-key/catalogue definitions.

| Native authority | Canonical projection or explicit boundary |
| --- | --- |
| Explicit active `model` | The existing desktop batch/live registries and shared local-family resolver select `transcriptionMode` and the active model key. Unknown/Apple-only routes are reported, never guessed as batch. Multi-purpose models remain batch when admitted by the batch registry. |
| `batchModel`, `liveModel`, `localModel` | Stored model slots map to their canonical model keys. An explicit active model wins over its corresponding remembered slot. Local engine/source submode is not invented. |
| `postProcessing.mode`, `.modelIdentifier`, `.temperature` | `postProcessingEnabled`, `postProcessingModel`, `postProcessingTemperature`; explicit native options override stale configuration mirrors. |
| `postProcessing.includeLexiconDirectives`, `.includeContextTags`, `.streamingEnabled` | `postProcessingIncludeLexiconDirectives`, `postProcessingIncludeContextTags`, `postProcessingStreamingEnabled`; the native options are their sole desktop authority. `lastRemoteModelIdentifier` is dormant picker recall and is not projected. |
| `postProcessing.outputLanguage` | Stored text, including explicit empty text, maps to `postProcessingOutputLanguage`; native nil suppresses a stale mirror without inventing a replacement string. |
| `postProcessing.customPrompt` | Value-free native-only notice, not transferable retention. No current Mac global scalar identity exists; the separate opt-in local capture below preserves the native source value without fabricating a profile. |
| `appearance` | Native system/light/dark maps to canonical textual appearance, not the native integer encoding. |
| `runAtLogin` | Explicit recorded boolean only; no OS registration query or side effect. |
| `automationEnabled` | Explicit `enableAutomationServer` boolean; no service admission or permission change. |
| Windows `textOutput` | smart/direct-only/clipboard-only map to smart/accessibilityOnly/clipboardOnly; cursor/replace-field map to insertAtCursor/replaceAll; restoration retains its explicit boolean. An explicit `appSwitchDelivery` maps to its canonical key. |
| Linux `textOutput` | Clipboard-only maps exactly; native paste has no exact Mac method and is reported instead of relabelled smart. Restoration retains its boolean. An explicit `appSwitchDelivery` maps to its canonical key. |
| `hotKey` | Exact shared Mac activation styles map to `hotKeyActivation`; press-to-toggle/unknown styles are native-only, never fallback conversions. Windows virtual-key bindings and Linux portal/fixed bindings do not become Carbon `selectedHotKey` data. |
| `voiceOutput` | Only explicitly stored auto-play/save/speed/pitch/SSML, favourite voices, Soniox region, language, quality and output format overlay their canonical keys. No execution getter, default materialization, clamping, provider selection or synthesis occurs. |
| `voiceOutput.modelID`, `.voiceID`, `.strictVoiceSelection`, `.trackUsage` | Native-only notices. The desktop provider/model/voice tuple is not assumed to equal Mac `defaultTTSVoice`; usage tracking is not a new canonical key. |
| `microphoneDeviceID` | Native-only notice; a native device identifier is not reinterpreted as a Mac audio-input UID. |
| `localUseGPU`, `azureSpeechResourceEndpoint` | Native-only notices; neither belongs to the canonical application-key set. |
| `automationLocalConsent`, `livePolishApproved` | Device-local approvals: native-only notices, never exported as portable grants. |
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

On its original base, the candidate passed 85 focused preference/Voice/hands-free/tail tests
(23 new projection regressions) and the complete portable suite: 1874 tests,
30 skipped, zero failures. Those counts were not re-run on the integration head.
Strict pinned SwiftLint passed all 17 candidate
and composition-resolution Swift inputs. All four Windows Swift projections
pass, including the production Windows projection hook and host tests. Those
header-backed projections do not prove native linking or runtime behavior.
Published `6dbefced3d899f8e3b4e61d668738443c78cfdb1` has exact-tree native
**failure** receipts: Windows x64 job115750034474 and ARM64 job115750175252
failed at `WindowsVoiceControls.cpp:318,344`; Linux job115750206937 failed at
`LinuxVoiceUsage.c:144`. The undeclared helpers are inherited from selected78ad.
Their checkout `5c9aec40f8f498e98a257d519b7f8814f41984b0` has published tree
`35c9ea0e7ac1d9b4b307c798c094ed155d814af0`; no native tests/fixtures ran.
These failures remain attributed to that frozen source, not replaced by local
capture checks, historical greens or later integration corrections.

Known limitations remain visible: no raw-file preservation guarantee for values
already changed by existing startup migrations or unknown members discarded by
existing nested typed decoders; no synthesized
Mac shortcut/Voice identifier, device UID, local submode or prompt record; no
collection-store collection, credential access, default reset semantics,
import/mutation, or atomic destination publication. The parent must preserve
category completeness and unknown/native-only material deliberately rather
than feeding these partial arrays into destructive replacement.

## Value-bearing native configuration source capture (ff6)

`DesktopHostController.configurationCapture(categories:selectedNativeFields:validateJSON:)`
and pure `DesktopHostConfigurationCapture.capture` return the **unchanged**
canonical preference projection alongside a separately selected
`DesktopNativeConfigurationCapture`. This non-Codable result is captured data,
**not itself an archive carrier, retained-unapplied payload, import contract or
proof of complete backup**. The isolated codec below is an opt-in transport seam;
parent aggregation and a safe target retention route remain separate. No schema format,
settings keys, controls, ABI, runtime behavior, profiles or credentials change.

`SpeakCore/DesktopNativeConfigurationField.swift` is the single noncredential
source-path/owner/type definition. Opt-in paths cover `postProcessing.customPrompt`,
separately `configuration.postProcessingSystemPrompt`, `microphoneDeviceID`,
`localUseGPU`, `azureSpeechResourceEndpoint`, `voiceOutput.modelID`,
`voiceOutput.voiceID`, `voiceOutput.ttsTrackUsage`, `hotKey` and `textOutput`.
Each selected entry names its actual Windows/Linux platform, source path and
native-settings versus legacy-configuration provenance, with explicit presence
and an optional raw `AnyCodable` value. Missing is not false, zero, empty text or
an explicit JSON null in these nullable source fields.
An empty selection captures no values. Unknown/credential/canonical-preference
selection paths fail; unknown/unselected material is reported by name only.

Native adapters identify only their actual host platform. The shared snapshot
reads stored authorities, not OS state, editor defaults, activation fallbacks,
Voice execution getters, providers or credential stores. In-memory source
metadata retains explicitly decoded native root values before nested typed
decoders could materialize defaults or discard members; an explicit write
replaces that source with the current stored authority. Persisted encoding is
unchanged. This is not recovery of raw values already lost before the snapshot
was created, nor a raw-file/full-wrapper backup. Root members the head's native
encoders write and the canonical projection already classifies (post-processing
lexicon/context-tag/streaming booleans; Voice favourites, Soniox region, language,
quality and format) are not reported as unresolved. `voiceOutput.strictVoiceSelection`
and `postProcessing.lastRemoteModelIdentifier` are not captured fields and are named
in `unresolvedPaths` when present.

Structured shortcuts/output must contain the classified host members (only an
unset `appSwitchDelivery`, which the native encoder omits, may be absent);
unexpected, missing, credential-like members and invalid UInt32 shortcut
numbers fail, never return a sanitized partial object. Unsupported stored
style/method strings remain raw, without executable-support claims. Azure
origins reuse `AzureSpeechConfiguration.batchResourceURL`: valid resource or
existing literal-loopback origins retain the original text, while userinfo,
query/fragment credentials and invalid URLs fail. Explicit blank endpoint
text stays blank rather than becoming a default. Prompt whitespace is not
trimmed; the native global prompt and any actually present legacy scalar remain
distinct owners, with no invented profile, UUID, matcher or Mac global setting.

Current Mac custom polish persistence is `DictationProfile.polishPrompt` in
UserDefaults `dictationProfiles` (`DictationProfileStore.swift:9,46-57`), applied
through transient `PostProcessingManager.sessionPromptOverride`. Its existing
canonical archive identity is `.profiles`, kind `profile`, existing UUID and
`value.polishPrompt` (`MigrationCatalog.swift:21,64-77,116`).
All seven auxiliary preference definitions were checked: none defines a global
prompt identity. Profiles require their separate raw collection owner; this
capture never synthesizes profile records from a global prompt.

On its original base, local qualification passed **101 focused tests** (including 16 new capture
regressions), **1890 full portable tests / 30 skipped / zero failures**, all four
Windows Swift projections and strict pinned lint on 22 Swift inputs.
`git diff --check` passes and `Package.resolved` is restored unchanged.
The first build was interrupted by concurrent local source edits; these results
come from the subsequent stable-source runs. No native/Apple, installed-app,
archive-carrier or full-parity acceptance is claimed for the frozen ff6 capture.
These counts were not re-run on the integration head.

## Isolated native configuration archive transport

`DesktopNativeConfigurationArchiveCodec.project(capture,checkCancellation:)`
returns immutable `DesktopNativeConfigurationArchive`: validated records,
original entries, read coverage and value-free unresolved source names.
`inspect(records,category:checkCancellation:)` validates records after generic
ZIP reading; `encode(archive,checkCancellation:)` and
`decode(data,checkCancellation:)` provide a strict deterministic JSON boundary.
`decode(record,checkCancellation:)` validates one transport record.
Only the existing closed `DesktopNativeConfigurationField` definitions are
accepted. No new settings, native capabilities or source inventories are added.

Transport records use category `.settings`, kind `nativeConfiguration` and
deterministic ID `native/<sourcePlatform>/<sourcePath>`. Their closed envelope
contains `schemaVersion: 1`, `sourcePlatform`, `sourcePath`, `provenance` and
`isPresent`; `value` exists exactly when present. An absent selected field still
has a record with no value. Explicit null, false, zero, empty text, whitespace
and source-platform structured values remain distinct. No target conversion,
defaults, trimming, clamping or fabricated profile/global-Mac identity occurs.
Windows-only structured data remains labelled Windows when read on Linux.

`DesktopNativeConfigurationCoverage` exposes the exact selected IDs and
`keysByKind`, with an explicitly partial `selectionScope`. Empty selection
produces an empty `selectedIDs` set, never nil/full-category scope.
These are **read coverage only**, not apply or replacement approval.
`permitsReplacement` and `isCompleteCategory` are always false, but those flags
do not change the generic planner's authority. Aggregators must not treat this
transport as an approved native importer or as a complete settings collection.
Existing canonical preference projection/catalogue, migration format, planner
and executable import acceptance remain unchanged. Canonical preference
validation still refuses the new transport kind; the Mac importer also has a
dedicated rejection regression, requiring an Apple test host to execute.

Per-record and aggregate encoded JSON, and raw decode input, are bounded by
`DataMigrationArchivePolicy.maximumJSONBytes` (128,000,000 bytes), not a separate
small prompt limit. Record count derives from the canonical field and source
platform enums. Depth eight covers every currently accepted closed shape;
parser/member bounds refuse excessive nested or unclassified material.
Cancellation is checked before work, between records and periodically while
scanning strings/input/output. Foundation coding itself is synchronous but
its input/output is bounded and cancellation is checked around each call.
Run large codec work on an owned cancellable off-actor worker, not a settings
admission queue or the PCM path.
Malformed JSON, duplicate keys (including escaped equivalents), identities,
platforms, provenance, presence/value mismatches, types, unknown members,
attachments and credential-bearing Azure origins abort explicitly rather than
returning filtered success.

Actual ZIP regressions exercise `DesktopMigrationArchive` transport with all
ten source paths, unknown-to-target Windows values and every presence state.
They require unchanged records, exact selection scopes, no notices and no audio
hashing. Generic ZIP reading is not the codec's strict raw-JSON parser: callers
must inspect returned records, and must not claim recovery of outer members
already discarded by the generic Codable reader. Unresolved/unselected names
are not value-bearing records and are not included in codec JSON.

This seam does **not** collect credentials or full wrappers, mutate native
settings/stores, import/apply/retain values on a target, collect profiles,
publish a destination, or establish full 91-key/feature/native/Apple parity.
Existing `6db` native compile failures and the integration's separate General
minimum-window UI failure are not repaired or qualified by this codec.

On its original frozen source, local qualification passed **117 focused tests**, including
16 new portable codec/ZIP regressions; **1906 full portable tests / 30 skipped /
zero failures**; all four Windows Swift projections; and strict pinned lint on
28 attributable Swift inputs. `Package.resolved` is restored unchanged.
The added Mac importer-rejection regression is linted but not executed locally;
Apple frameworks/runtime and actual Windows native linking/runtime remain
unqualified. Holding-branch publication does not select an integration source
or widen target retention/import/apply acceptance. These counts were not
re-run after cherry-picking onto the integration head.

## Local immutable retained configuration capsule candidate

`DesktopNativeRetentionMergePolicy.plan(existing:incoming:checkCancellation:)`
validates both native record sets through the frozen codec and returns proposed
records, additions, idempotent IDs and explicit conflicts. Equal entire
envelopes are idempotent; differing presence/raw values conflict, while invalid
provenance/schema/identities are refused before a candidate is returned.
Foreign Windows/Linux identities remain separate. Empty incoming arrays never
clear retained records; an absent selected value cannot replace a present one.
`hasConflicts` is a report, not a permission to write or apply.

`DesktopNativeRetainedCapsule.create(archive,in:identifier:storage:publication:checkCancellation:)`
creates one **immutable** `native-retained-<UUID>` private leaf containing
`records.json`. It validates strict encoded bytes before creating anything,
uses the existing protected `DesktopMigrationArchive.Storage` creation seam,
flushes owned staging, validates the reread staging bytes and delegates
no-replace publication through required `DesktopFilePublication.Copy`.
Native callers must supply their actual `WindowsMigrationArchive` or
`LinuxMigrationArchive` storage/publication operations. There is no default
public-permission Windows fallback, global Root retention pointer, update,
replace, delete, settings write or automatic native importer.

`reload` validates the file against the instance's held original bytes and
strictly decodes it. `read(from:)` performs bounded strict restart inspection.
Restart validation proves current codec validity, **not** historical
authenticity if an external writer substituted different valid bytes; directory
naming alone establishes neither ownership nor mutation authority.
The published `990ff362` implementation checks and opens by path without
canonical strict-reader evidence; its check/open race remains a qualification
limit. The subsequent local reader candidate below reuses stronger canonical
point-in-time fences, not atomic held-descriptor reads or mutation CAS.
`exportProjection` returns only `.settings` native records with exact selected
IDs (including an explicit empty set), never complete/replacement scope.
Canonical/Mac automatic import continues to reject `nativeConfiguration`.

Reusing an existing UUID leaf refuses before modifying it. Prepublication
failure/cancellation removes only the invocation's named unpublished stage;
empty-directory removal is nonrecursive, so unrelated children are not deleted.
Once publication may have committed, an explicit published-effect failure keeps
the capsule rather than deleting it, retrying or claiming success.
Staging removal uses native nonrecursive `unlink`/`_wunlink`, after checking for
a regular file. A directory substituted for staging is refused without deleting
its children, both before and after publication. Directory cleanup itself uses
nonrecursive `rmdir`/`_wrmdir`; neither path recursively deletes children.
`DesktopNativeRetentionCleanupFailure` retains typed `primaryError` and
`cleanupError`; `DesktopNativeRetentionPublishedFailure.underlyingError`
preserves the original failure, including cancellation. Their user-facing
messages do not interpolate underlying errors, paths or captured values.
Write handle cleanup attempts close once, preserving a dual failure and never
retrying a failed close. Canonical read-handle cleanup follows its own selected
single-close contract.
Construction/reload/export run off the UI/settings-admission/PCM paths.

The frozen `86a` IO primitives provide protected creation and exclusive
publication, **not** identity-conditioned mutation CAS or owned transactional
replacement journals. Read seals and process locks do not fill that gap.
Mutable aggregate retention, conflict-resolution writes, transactional
replacement and safe apply remain explicitly blocked on that separate
authority contract. This local capsule is not selected for integration or
connected to import/export UI.

Vocabulary's `vocabulary.json` opaque-source carrier is a separate peer-owned
contract, not field ten or this settings capsule. It may contain sensitive user
content/unknown members; no noncredential classification, scanning, upload or
automatic carrier admission is inferred. Frozen native-field definitions,
settings codec/parser, catalogue and source acceptance remain unchanged here.

The prior `f151d0cc` candidate added **18** merge/capsule regressions, including actual
publication followed by child-task cancellation. That case reports
`DesktopNativeRetentionPublishedFailure`, strictly reloads the complete original
envelope after restart, proves one publication and preserves unrelated Root and
capsule-side files. It neither retries nor deletes committed data.

For that prior source only, the cached WSL Swift toolchain ran these commands through the
`validate-native-retention.sh` session wrapper, which restores `Package.resolved`:

- `SPEAK_PORTABLE_CORE=1 swift test --scratch-path /tmp/jsti-settings-eacacdaf --jobs 4 --filter 'DesktopNativeRet|DesktopNativeConfiguration|DesktopHostConfigurationCapture|DataMigrationPreference|DesktopHostPreferenceArchive|DesktopHostHandsFree|DesktopHostRecordingTail|DesktopHostVoiceConfiguration|DesktopHostKeywordConfiguration'`:
  **135 passed / 0 failures**.
- `SPEAK_PORTABLE_CORE=1 swift test --scratch-path /tmp/jsti-settings-eacacdaf --jobs 4`:
  **1924 tests / 30 skipped / 0 failures**.
- `bash scripts/typecheck-windows-swift.sh --jobs 4` (CRLF-normalized script,
  `SPEAK_WINDOWS_TYPECHECK_DIR=/tmp/jsti-feedback-windows-typecheck-eacacdaf`):
  all four Windows Swift projections passed; these are compile-only stub graphs.
- `swiftlint lint --strict --config .swiftlint.yml --baseline .swiftlint-baseline.json`
  with the pinned 32-path Swift input set in an LF-normalized mirror:
  **0 violations**.

Native Windows/Apple runtime and installed-host durability remain unqualified.
This is an isolated local candidate, not integration selection, a mutable
retention transaction, a safe target importer or full settings parity.
The scoped nonrecursive-cleanup/error-preservation repair adds six regressions
(24 total merge/capsule/IO cases). They preserve the unrelated sentinel when
`unpublished.json` is replaced by a directory before failed publication or
after successful publication, inspect both typed failures, and prove
operation-only, close-only, dual-failure and successful handle cleanup each
closes exactly once. The existing post-publication cancellation case now also
inspects the original `CancellationError`.

Fresh receipts use the same commands above through
`validate-native-retention-repair.sh`, with distinct repair log paths:
**141 focused / 0 failures**, **1930 full portable / 30 skipped / 0 failures**,
all four Windows compile projections passed, and strict lint of the expanded
**34-path** Swift set returned **0 violations**. These qualify the repaired
source, not native Windows/Apple runtime, strict identity-bound IO or mutation
authority. The prior 135/1924/32-path receipts remain prior-source evidence only.

### Local canonical strict-reader candidate

The capsule imports only these exact canonical modules from selected
`578cd14f105273cfeddb4e38e792e709f9e28954`, not that branch's profile/History/UI work:
`DesktopOwnedAppDataFileReadError.swift` (`5d1de758a6045b596bf5925e6842849dd1fb409d`),
`DesktopOwnedAppDataFileReader.swift` (`fe9c69f02b83c15c65d88dd2830f001aa432a15a`) and
`DesktopOwnedAppDataFileReader+Strict.swift` (`db7e0a4f3bd5be189256d750b153313dd19d8bea`),
all under `Sources/SpeakDesktop`. On the integration head these readers were
already present from the earlier owned-AppData reader integration; the capsule
uses the head copies. The head `+Strict` file differs from the cited blob only
by `directoryChain` being internal rather than private.

Staging/published reads use `readStrict` and `revalidateStrict` around codec
inspection, preserving the canonical byte budget, cancellation and original
typed read/IO causes. A held capsule keeps both its original sealed bytes and
`StrictReceipt`; reload/export revalidate the original receipt, so identical
bytes alone cannot establish the original held source. The receipt compares
file and directory-chain identity as well as bytes; the same-byte new-file
identity case is exercised locally.
Restart inspects the current snapshot only, never historical authenticity.
Missing records fail rather than becoming empty settings. Missing required
native metadata fails closed with `insufficientIdentity`, including Windows
hosts whose Foundation metadata cannot support this contract; there is no
fallback to the older path-only reader.

These are bounded pre/post byte/file/directory-chain point-in-time fences.
They are not atomic held-descriptor reads, do not eliminate every check/open
or ABA race, and grant no mutable Root, deletion, journal or write-CAS authority.
Canonical generic-scanner adaptation is a separate milestone and remains
outside this reader candidate.

The isolated directory-only replacement fixture compares the **full canonical
file identity**, not just inode and bytes. It explicitly skips on this WSL
filesystem because moving the file changes that identity. Exact bytes and
unrelated sentinels in both directories remain checked, but this does **not**
provide an independent directory-chain-only rejection proof on this host.
No metadata normalization or synthetic identity is used to manufacture one.
Native Windows/Apple runtime and that independent directory-only case remain
unqualified.

Final candidate receipts from `validate-native-retention-reader.sh`:

- `SPEAK_PORTABLE_CORE=1 swift test --scratch-path /tmp/jsti-settings-eacacdaf --jobs 4 --filter DesktopNativeRet`:
  **34 tests / 1 explicit identity-fixture skip / 0 failures**.
- The same full portable command above: **1940 tests / 31 skipped / 0 failures**,
  including the explicitly unproven directory-only case.
- Strict lint with the pinned expanded **38-path** Swift set: **0 violations**.
- All four Windows compile projections passed before the approved test-only
  refinement. Their **1318** source/resource/HostTests/manifest/script inputs
  remain identical, SHA-256
  `DC68A624962469C190D7B1F0214E1D27FB7F7C1E140AE804BCC4069D124ED9D5`.
  `SpeakDesktopTests` is outside those graph targets; no extra graph run or
  native runtime acceptance is inferred from the final test change.

Earlier 33/1939 receipts describe the pre-refinement test source only. The
selected three canonical source blobs remain byte-identical throughout.
These receipts were recorded on the original holding branch and were not
re-run on the integration head.

### Isolated canonical member-preflight delegation candidate

After freezing reader commit `3c88f274`, `NativeConfigurationJSONScan` delegates
to the separately selected `JSONMemberPreflight` rather than owning a second
state machine. Only `Sources/SpeakCore/JSONMemberPreflight.swift` (blob
`dd5603ef399859c946b647909da85f40e448fc55`) and its seven-case test corpus (blob
`674c22469281a51c57ad6e2ed2044b01326cccd8`) are imported from qualified peer
`75a81b5f188a7ea89c1e907c53e7201a6470e0fe`; its native-source codec, metadata
and branch ancestry are not composed. On the integration head both blobs were
already present (peer `75a81b5f` was cherry-picked as `6e0602c4`), so this
delegation adds only the adapter and its scan tests.

The thin adapter retains the original `86a` scanner's settings contract:
canonical 128,000,000-byte budget; depth 8; 4096 tokens; canonical
field-count times source-platform-count root records; 32 object keys;
512 encoded key span (closing quote minus opening quote); absolute-index,
key-lookahead and completion cancellation checks at the original 4096 stride.
It retains `Malformed or unbounded native configuration JSON.` for guard
failures and propagates Foundation key-decoding errors without conversion.

The imported corpus and adapter-specific reference/edge/cancellation cases
exercise these original expectations. Preflight still does not own JSON
grammar, root shape or migration schema validation: Foundation's existing
trailing-comma behavior is not silently tightened. Archive codec inspection,
the closed field inventory and automatic apply/import admission remain
unchanged. This is not a complete repository-wide deduplication claim or a new
native-source, profile, capsule or write authority.

Fresh isolated qualification through `validate-native-preflight-adapter.sh`:

- `SPEAK_PORTABLE_CORE=1 swift test --scratch-path /tmp/jsti-settings-eacacdaf --jobs 4 --filter 'JSONMemberPreflight|NativeConfigurationJSONScan|DesktopNativeConfiguration'`:
  **34 tests / 0 failures**, including the existing canonical byte-budget,
  escaped/aggregate-size, duplicate-member and ZIP roundtrip regressions.
- Full portable command: **1950 tests / 31 skipped / 0 failures**. The inherited
  independent directory-only identity-fixture skip remains explicit and is not
  converted into acceptance by this adapter.
- Strict lint in its separate LF-normalized **41-path** source mirror:
  **0 violations**.
- A fresh four-target Windows compile-projection run passed; no reader
  qualification or peer/component receipt is substituted for this source.
  These are still stub compile graphs, not native Windows/Apple runtime.

The imported helper/corpus blobs remain exact. Reader/capsule code and its
qualification limits are unchanged; no field/catalogue/schema, automatic
import/apply or full-parity admission is inferred.
These receipts come from the original holding branch and were not re-run on
the integration head.

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

Each automatic utterance now resolves the profile for the application captured
with it through the canonical resolver, as Mac `startSession(.handsFree)` does.
Windows reads the retained target's process, or for explicit clipboard output
the foreground process without probing an editable field or creating an
insertion worker. X11 reads the active window's process (`/proc/<pid>/exe`) for
the canonical Linux executable matchers; Wayland exposes no external app
identity, so normal app settings apply and the recording's profile notes say
so. An unreadable app identity likewise keeps normal app settings. The model,
language and polish choices remain record-bound; no override is persisted into
app defaults. Unavailable models refuse the utterance without fallback. A route
requiring a different PCM rate from the armed detector refuses before creating
a WAV or starting a provider, with guidance to arm again in the destination
app. The preferred microphone and output method remain detector/run-owned.

Legacy-path recording configuration, live options, Azure endpoint and capture
rate are snapshotted before asynchronous startup and retained through
finalization; owned dictation already freezes its inputs at admission.

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

## Capture warm-up, remote paste and Mac-only delivery settings (source only)

`SpeakCore/CaptureDeliveryPreference.swift` registers five canonical Mac keys
in the shared generic editor, strict validation and JSON transfer. Mac defaults
apply: capture preparation and key-press warm-up on, streaming insertion and
remote paste off, History interval 5 s. The interval accepts 0...30 so stored
Mac values below the 1 s slider minimum still import; out-of-range values are
rejected with the rest of that configuration, as for every field. No
Swift/native build, test or device check has run for this source.

- **`audioPreWarmingEnabled`.** At each idle transition, Windows
  (`WindowsCapturePrewarm.cpp`) resolves the saved or default communications
  capture endpoint, checks that it is active and keeps the Core Audio runtime
  loaded. It never activates an audio client, so no stream runs, nothing is
  read and no microphone indicator appears. This is narrower than the Mac
  engine prewarm: no audio is kept and no audio session is open, so the gain is
  limited to endpoint resolution and library loading. Each idle period holds it
  for at most 10 minutes. It is released on recording, busy work, device change
  (the microphone-warning path), settings or credential changes, disable and
  shutdown, and renewed only by a later idle transition, never by a timer.
  Linux has no adapter; the key is stored and has no effect there.
- **`warmMicrophoneOnKeyPress`.** On Windows and Linux, a hold or double-tap
  key-down opens a discarding capture on the shortcut's microphone before the
  gesture resolves. Press-to-toggle does not, because it starts recording at
  once. The capture closes when the recording capture is ready, after the Mac
  safety bound max(2.5, hold + 2 × double-tap + 1) s, or on device, settings,
  credential or shutdown changes. It never opens while a recording, hands-free
  run, busy operation or automation-owned dictation exists. As on the Mac, a tap
  that starts nothing briefly lights the microphone indicator; nothing is
  recorded or sent. Unlike the Mac, its 1.5 s pre-roll is not handed to the
  recording, so speech before the recording capture opens is not kept.
- **`streamingInsertionEnabled`.** Stored and transferred only. The Mac streams
  only into an allowlist of TextEdit and Notes and otherwise pastes once at the
  end. Windows and Linux have an empty allowlist: text is inserted once when
  dictation ends. Append-only insertion of live finals was rejected because
  voice commands, vocabulary corrections, Auto-Clean and post-processing
  transform the final text, and a live final can still replace interim text.
  Partial output would leave untransformed text in the field.
- **`pasteRemoteTranscriptsAtCursor`.** On Windows and Linux, the shared
  `RemoteTranscriptArrival` rule decides each History record that iCloud sync
  saves. It acts only on records new to this host, from an iPhone or Apple
  Watch, with text, and dated within 60 s (and no more than 60 s ahead). It is
  off by default. The newest qualifying arrival in a sync pass goes through the
  saved text output to the field focused at that moment, so Clipboard only
  copies instead, and the status line reports the outcome. It never runs during
  a recording, hands-free run, automation dictation or pending output. Other
  arrivals stay in History, and there is no notification with Paste and Copy
  actions. Two limits make it rarely active. Desktop sync polls every 300 s with
  no push, so a capture is pasted only if a pass lands within 60 s of it. Desktop
  sync also joins only the Mac container, so iPhone History in
  `iCloud.com.justspeaktoit.ios` never arrives; only phone or watch records in
  the Mac container, the ones the Mac would act on, qualify.
- **`historyFlushInterval`.** Stored and transferred only. The Mac batches
  History writes on this interval. Windows and Linux save each History record
  durably as its operation completes, so a timed flush would only delay
  durability; the generic editor labels it as a Mac-only value.

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

## API Keys pages (Windows/Linux source only; NOT_RUN)

The Mac's API Keys destination
(`Sources/SpeakApp/Views/Settings/SettingsView+APIKeys.swift`) now has a native
Windows equivalent: **Transcription → All API keys…** opens a dialog, and
`WindowsNative.openAPIKeys()` (`jsti_window_request_api_keys`) is the single
entry hook; the setup guide and the Open API Keys Settings action shortcut use it. It lists one row per credential Windows
can use, projected from the canonical catalogues rather than a Windows-owned
list (`DesktopHostAPIKeys.swift` `apiKeyCatalogEntries`): every non-local
transcription batch/live provider, OpenRouter post-processing, each Voice Output
credential slot and the Voice account providers, merged by identifier with
their uses shown (`SpeakCore/APIKeyCatalog.swift`). Azure entries take the
existing `key` + region form; the configured Azure Speech resource endpoint is
used when checking.

- Each row shows **Not set**, **Saved** with a masked last-four suffix, or
  an unreadable-store message. The dialog never receives a stored key; typed
  text is wiped from the dialog's buffers once handed to the host.
- **Save key / Replace key** sanitises and checks the key before writing it,
  matching the Mac's save-then-validate flow; a failed check does not write.
  **Remove key** asks for confirmation first. **Check validity** checks typed
  text, or the stored key when the field is empty. **Get API key…** opens the
  provider's https key page.
- Checking reuses the shared provider validators where they exist;
  `SpeakCore/APIKeyValidation.swift` adds portable probes for OpenRouter,
  Gladia and Azure Speech (resource health or voice list). Alibaba is
  format-checked only and is not executable on Windows.
- Storage is the same Windows Credential Manager identifier the Transcription,
  Post-processing and Voice editors use, written through the same path
  (cloud sync observes it when enabled). Changes therefore show in both places. The dialog
  re-reads every row when it opens and after each action.
- `trackedKeyIdentifiers` follows the Mac semantics: saving a non-empty key
  registers its identifier, removing it unregisters it, and opening the page
  reconciles the list against what the store actually holds. The list lives in
  `trackedKeyIdentifiers.json` beside the desktop settings. It holds identifiers
  only, is never exported, and does not drive readiness, which still reads the
  store directly. Keys saved from the embedded editors are recorded too.
- Partial: keys imported by **Import API keys my Mac syncs** are written
  without recording; the next page refresh reconciles them. Operations are
  refused while recording or a Voice Output task runs. Portable catalogue,
  masking, tracking and validation tests (`Tests/SpeakPortableTests/APIKeyCatalogTests.swift`)
  and the native dialog self-test (`jsti_api_keys_self_test`) are authored, but
  none has been built or run, and no physical credential lifecycle evidence
  exists.

Linux now has a dedicated libadwaita **API Keys** window, opened from General's
**Manage API Keys...**, the Open API Keys action shortcut, or Troubleshooting's
credential findings. Its searchable provider picker consumes the same shared
`apiKeyRows` catalogue and masked state; it does not copy provider entries or
redirect to an unrelated feature. Save and validate, Check key, confirmed Remove
saved key, Refresh and Get provider key reuse the shared Host workflow and the
same Secret Service entries as the embedded editors. Azure resource configuration
remains in Transcription. Opening/refreshing reads local key state only; checking
or saving explicitly contacts the selected provider.

The form never prefills stored secrets, disables undo, clears typed input on
selection, dispatch, loss of availability and close, and wipes its native
callback buffer after handoff. Request UUIDs fence stale/closed-window results;
removal confirmation is also bound to the current window and provider selection.
The settings queue admits a separately owned cancellable operation rather than
waiting for keyring/network work. Closing cancels pending validation; a vault
write already admitted may finish, which the form states explicitly. Cancelled
Host requests cannot newly admit validation/storage or reconcile the tracked
index after cancellation.

Portable owner/cancellation regressions and a synthetic native lifecycle fixture
cover held work, stale requests, selection/privacy clearing, removal fencing
and invalid row rejection. They are **NOT_RUN** locally. Actual keyring unlock,
provider validation and physical/native acceptance remain required. Mac status
filters, sorting, account balances and the complete paid/sync management surface
are not implied by this core credential-management window.

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
General's **Save ZIP backup** already writes a Mac-compatible archive
(`DesktopMigrationBackup`). **Restore backup** on Windows now reads one, maps
its categories, previews merge and replace, asks for confirmation and rolls
back on failure for History text and app profiles only; see below. Restoring
settings, audio, credentials, vocabulary, connections and models remains a
gap. No ZIP is misidentified or silently imported as portable preferences.

### Restore backup (Windows source only)

General > **Restore backup...** opens a Mac-compatible ZIP through a native
picker. The settings queue only admits the request. Reading, validation and
planning run on an owned, cancellable worker that writes nothing and removes
its private staging directory (`DesktopMigrationRestore.prepare`,
`DesktopHostMigrationRestore.swift`). Records pass the cancellable
`DataMigrationRecordValidation.validate(..., checkCancellation:,
recordValidator:)` overload. Duplicate identities, including those that
differ only in letter case, refuse the whole backup.

The preview lists each applied category's counts (new, updated, removed,
before and after), conflicts, skipped items and every category that is kept in
the backup but not applied. It never shows transcript text, profile contents,
identifiers or credential values. Nothing is written until the user picks an
action in the native dialog (`WindowsMigrationRestore.cpp`). Cancel is the
default button. Replace needs a second confirmation that defaults to No. Each
preview has a single-use token, so a stale or repeated answer is refused.

- **History text** always merges. It follows the canonical planner, so
  equivalence ignores the root ID and `desktopHistory.id`. A differing backup
  version becomes a new local item: its planned ID is materialised with
  `DataMigrationHistoryValue.value(..., id:)` before strict native mapping.
  `originPlatform` is always nil, so `removeSyncedCopy` can never treat it as a
  CloudKit copy. The backup's provenance stays in `migrationMetadata`.
  Items deleted on this device and synced copies are never restored or
  overwritten. Saved audio is not restored.
- **App profiles** can merge (this device's version wins conflicts) or
  replace. Replace skips a category that is absent from the backup. It keeps
  every existing profile when a notice is prefixed with the category title.
  A missing or damaged category never becomes an empty replacement.
- **Settings, credentials, recordings audio, vocabulary, connections and
  models** are listed as kept in the backup but not applied. Credentials are
  never imported automatically and their values are not read into the preview.
  Native configuration, hotkey, microphone and device-path values are not
  touched.

Apply re-reads the current History and profiles and refuses if either changed
since the preview. It then writes profiles followed by each History item.
Before writing, it snapshots the original bytes of every file it touches
(`DesktopRecordingStore.applyMigrationRestore`). On cancellation or failure,
it restores those bytes, removes the files it added and reports whether the
rollback succeeded. Portable tests are in
`Tests/SpeakDesktopTests/DesktopMigrationRestoreTests.swift`.

Not yet done:
- Linux has the shared code but no GTK entry point; `LinuxHostPlatform` keeps
  the default nil restorer.
- Restored History is not pushed to iCloud sync immediately.
- There is no native self-test or screenshot receipt for the dialog yet.

## Local live transcription (Windows source only)

Local now offers Batch and Live on Windows. Live lists one entry per pinned
whisper.cpp catalogue model the host executes (`DesktopLocalStreaming.options`),
named `<model> (on-device, live)` and identified by the Mac's
`local/streaming/whisperkit/...` value, so History, profiles and selections
name the same model on every platform. It reuses the batch model's verified
download, runtime and removal lease: there is no second download, and the
Local models label (for example "download in Local models") also appears on
the live entry.

`DesktopLocalStreamingClient` converts captured 16 kHz PCM, detects speech
with an absolute and adaptive-noise-floor RMS gate, and on one worker task
re-recognises the current window about once a second as interim text. A
0.6 s pause or a 20 s window commits that window as a standalone final;
finishing recognises the remainder. Silence never reaches the model, so a
silent recording stays empty. Interim and final text use the same live
transcript callbacks, HUD preview and `finishLive` History/output path as
remote live providers, with no key and no network.

The remembered `localLiveModel` slot sits beside `batchModel`, `liveModel` and
`localModel`; the native Mode picker selects it when Local is the source.
Model comparison excludes live entries because their batch model is already a
candidate. File import and automation transcription of a local live
selection use its batch model.

Remaining gaps: no compiled or device receipt; Linux stays Local batch only;
imported Hugging Face models are batch only; Auto-Clean live polish is not
offered for local live; profiles cannot override to a local live model;
configuration transfer does not map `localStreamingModelSource`; a model whose
file fails its digest during streaming is reported, not removed automatically
as in batch; sherpa-onnx and Parakeet streaming sources are Mac only.

## First-run setup and permissions (Windows source wired; Linux model only)

The Mac's `OnboardingView`, `PermissionsManager`, `PermissionRecoveryHelp` and
`DashboardPermissionsSection` journeys have a shared desktop model and a Windows
native surface. Earlier baseline notes that called onboarding and permission
remediation missing on Windows are superseded by this source.

- **Shared model** (`SpeakCore/DesktopOnboarding.swift`,
  `SpeakDesktopHost/DesktopHostOnboarding.swift`): ordered steps (welcome,
  microphone, text insertion, transcription route, shortcut practice, optional
  post-processing, done), their actions and plain-language guidance; permission
  items with status, guidance and blocking summary. Completion is stored under
  the Mac's canonical `hasCompletedOnboarding` key, with the last step reached,
  in `onboarding.json` beside `settings.json`. An existing install with saved
  settings is adopted as complete, so upgrades do not see the guide.
- **Windows setup guide** (`SpeakWindows/WindowsOnboarding.swift`,
  `CWindowsSupport/WindowsOnboarding.cpp`): a modeless window owned by the main
  window, opened on first launch after the controller is ready and again from
  About, **Run setup again**. Steps open the existing native dialogs (Text
  output, Local models, Keyboard shortcut, Post-processing), Windows microphone
  privacy settings (rechecked on return), the Permissions window and a test
  dictation through the tray's Start/Stop. The route step reports whether the
  selected remote model has a saved key. Provider keys go through
  `WindowsOnboardingHooks.shared.openAPIKeys`, which the API Keys page sets
  at startup to open its dialog; unset, it falls back to Transcription.
  Skip and Finish both record completion. The guide is modeless so the global
  shortcut keeps working while practising; the app never types into its own
  windows, so practice text appears in the main window's transcript, ready to copy.
- **Windows Permissions window** (`SpeakWindows/WindowsPermissions.swift`,
  `CWindowsSupport/WindowsPermissions.cpp`): live rows for microphone privacy
  (global and desktop-app access, from the CapabilityAccessManager consent
  store), text insertion (UI Automation/SendInput availability, and the chosen
  output mode), elevation mismatch (an elevated app cannot type into
  non-elevated apps and vice versa), the automation pipe setting, notifications
  (not used by the Windows app, shown as not applicable) and the startup task
  (`DesktopLoginItemState`). Each row has guidance mirroring
  `PermissionRecoveryHelp` and a remediation button: `ms-settings:` privacy
  pages through `ShellExecuteW`, or the app's own Text output/General pages.
  The window rechecks when it is reactivated after Windows Settings and on
  **Check again**.
- **Dashboard warning**: a blocked microphone or unavailable insertion route is
  named in the ready status line (`DesktopHostController.permissionWarning`),
  the Windows equivalent of `DashboardPermissionsSection`.
- **Limits**: the automation row reflects the saved setting, not whether the
  pipe is currently listening; there is no notification-area "Run setup"
  entry; all native and Swift code is uncompiled and unqualified on Windows.
- **Linux**: shares the step and permission model; no native GTK guide or
  Permissions page yet. Portal/PipeWire microphone access and Wayland
  insertion limits need their own adapter before Linux can present the model.

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
| Keys | `Sources/SpeakDesktopHost/DesktopHostCredentials.swift`, `DesktopHostAPIKeys.swift`, `SpeakCore/APIKeyCatalog.swift`, `SpeakWindows/WindowsNative.swift`, `SpeakWindows/WindowsAPIKeys.swift`, `SpeakLinuxPlatform/LinuxCredentialStore.swift` |
| Shortcuts | `Sources/SpeakWindows/WindowsHotKey.swift`, `Sources/SpeakLinux/LinuxShortcutGestures.swift`, `SpeakCore/HotKeyGestureMachine.swift` |
| Voice | `Sources/SpeakDesktopHost/DesktopHostReadAloud.swift`, `SpeakWindows/WindowsReadAloud.swift`, `SpeakLinux/LinuxReadAloud.swift` |
| General | `Sources/SpeakDesktopHost/DesktopHostSettings.swift`, `DesktopHostLoginItem.swift`, `SpeakWindows/WindowsLoginItemHost.swift`, `SpeakLinux/LinuxLoginItemHost.swift` |
| Automation | Windows per-user named pipe, `WindowsAutomation.swift`, `WindowsAutomationSetup.swift` and General › CLI and MCP setup (`CWindowsSupport/WindowsAutomationSettings.cpp`, source-only); Linux `LinuxAutomation.swift`, shared Host commands and `SpeakLinuxAutomation` private Unix socket/`speak` journey (source-only, native qualification pending); `--toggle` remains |

Paths named relative to `Sources` in a cell inherit the preceding `Sources/`
prefix. Missing rows cite the canonical Mac definition above and their native
replacement/nearest implemented surface; they do not assert hidden support.

| Mac key | Windows / Linux outcome | Evidence or remaining work |
|---|---|---|
| appearance | Equivalent / Equivalent | General; system/light/dark native schemes |
| visualDensity | Wired; native acceptance pending / Wired; native acceptance pending | General Normal/Compact choice; strict shared configuration, JSON transfer and native page/card/sidebar spacing |
| transcriptionMode | Equivalent / Equivalent | Models; Remote Batch/Live; Local Batch, plus Local Live on Windows (source only, see local live transcription) |
| liveTranscriptionModel | Partial / Partial | Models; implemented transport routes only; Apple Speech and unavailable providers are not substitutes |
| batchTranscriptionModel | Equivalent / Equivalent | Models; independent remembered batch model |
| localTranscriptionModel | Partial / Partial | Models; pinned whisper.cpp catalogue plus explicit Hugging Face GGML imports (`desktop-huggingface-import.md`); not the Mac WhisperKit/Core ML or sherpa-onnx runtimes |
| localTranscriptionMode | Source wired, unqualified / Partial | Windows Local Batch and Live: Live streams a pinned downloaded whisper.cpp model in process with VAD-bounded windows and shares the remembered `localLiveModel` slot; Linux remains Local batch only |
| localStreamingModelSource | Partial / Missing | Windows Local Live selections use the Mac's WhisperKit live identity (`local/streaming/whisperkit/...`) for pinned Whisper models, saved in the host `localLiveModel` slot; configuration transfer does not map the Mac key yet. Sherpa-onnx and Parakeet sources are not offered because no desktop host runs them |
| postProcessingEnabled | Equivalent / Equivalent | `DesktopHostPostProcessing.swift`; desktop default remains disabled. Source proposal adds explicit local rules opt-in without credential access; remote remains opt-in |
| postProcessingModel | Partial / Partial | Shared remote catalogue, built-in Local Cleanup and downloaded GGUF LLMs through the native llama.cpp runtime (`desktop-local-llm-cleanup.md`, source only); Apple Foundation Models and MLX remain unavailable |
| postProcessingTemperature | Wired / Wired | Config; range 0...1, OpenRouter request |
| postProcessingOutputLanguage | Wired / Wired | Config; remote cleanup system prompt; built-in rules explicitly ignore it |
| postProcessingIncludeLexiconDirectives | Source wired / Source wired | Native post-processing switch, Mac default true, options/session snapshot and strict transfer; excludes saved directives from remote requests when false |
| postProcessingIncludeContextTags | Source wired / Source wired | Native post-processing switch, Mac default true, options/session snapshot and strict transfer; excludes saved context tags from remote requests when false |
| textOutputMethod | Equivalent / Partial | Output; Windows Smart/direct/clipboard; Linux paste/clipboard, no direct accessibility insertion |
| restoreClipboard | Equivalent / Partial | Output; Windows restoration; Linux X11 owned plain-text restoration only. Wayland capability-gates the control, retains its saved X11 choice and leaves pasted text on the clipboard |
| appSwitchDelivery | Source wired, native qualification pending / Source wired with explicit targeting gaps | Shared Mac policy/type and native chooser; sole native-options persistence, strict transfer and recording snapshots. Windows safely addressable native fields support original-background and guarded delivery-time retarget; Linux switched destinations copy only until a separately safe field route exists. See application-switch delivery above. |
| showHUD | Wired / Wired | Config + HUD |
| appVisibility | Source wired; native acceptance pending / Persisted only | General; Windows taskbar and notification area, notification area only or taskbar only, applied at launch and live. GTK has no portable tray, so Linux stores and transfers it. See app shell above |
| showStatusBarIconInDockOnly | Apple-specific / Apple-specific | No Dock on Windows/Linux; retained opaque through import/export, not shown |
| compactStatusBarIcon | Source wired; native acceptance pending / Persisted only | General; Windows compact notification-area tooltip and menu. Linux stores and transfers it |
| runAtLogin | Equivalent / Equivalent | General; native startup task/login entry, OS status displayed |
| recordingsDirectory | Partial: fenced / Partial: source only | Mac path retained, never executed. Device-local chosen folder via verified recording locations: Linux Housekeeping chooser; Windows reports unavailable while `WindowsRecordingRegistry` identity/restart integration is fenced. Existing audio never moves. See recordings folder above |
| hotKeyActivation | Equivalent / Equivalent | Shortcuts; press/hold/double-tap/combined styles; Linux portal availability caveat |
| holdThreshold | Wired / Wired | Config + shared gesture machine; 0.2...1.5 s |
| doubleTapWindow | Wired / Wired | Config + shared gesture machine; 0.2...1 s |
| trackedKeyIdentifiers | Equivalent source only; NOT_RUN | Keys; identifiers only, in `trackedKeyIdentifiers.json`. Saving a key from the shared editors registers its identifier and removing it unregisters it. Both desktop API Keys windows reconcile the list against the store; cancellation skips reconciliation. |
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
| historyFlushInterval | Persisted only / Persisted only | Generic 0...30 s field; History stays durable per operation (see Capture warm-up section) |
| silenceDetectionEnabled | Executable; qualification pending / Same | Native switch; initial quiet and configured silence stop the existing manual recording/finalization pipeline |
| handsFreeDictationEnabled | Sound-activation replacement; per-slice qualification / Same | Fresh target and app profile per utterance (Windows/X11; Wayland uses normal settings with a note), immutable provider options, record-bound output evidence; rate changes refuse/rearm; not Apple's classifier |
| silenceThreshold | Executable; qualification pending / Same | Canonical range/default and Mac PCM meter; native editor feeds manual silence and sound activation |
| silenceDuration | Executable; qualification pending / Same | Canonical hold/range feeds manual auto-stop and hands-free debounce; existing recording tail is retained |
| connectionPreWarmingEnabled | Partial / Partial (source only; NOT_RUN) | Canonical intent round-trips. Separate native session approval allows a credential-free HEAD on the shared OpenRouter pool with a 5-second cancellation budget, only at idle after acknowledged ordinary capture in the current process/configuration and its real cleanup credential check. No probe before successful capture after restart; approval and capture evidence are transient. Completed-request remote cleanup only; native live WinHTTP/NIO and streaming cleanup's owned delegate sessions cannot reuse this pool. Owned/hands-free capture does not provide this witness. Existing device/absence notifications invalidate readiness; no new network/sleep monitor, idle timer/retry or guaranteed latency improvement. |
| audioPreWarmingEnabled | Source wired, unqualified / Persisted only | Bounded idle endpoint preparation without opening the microphone; no Linux adapter |
| warmMicrophoneOnKeyPress | Source wired, partial / Source wired, partial | Discarding key-down capture with Mac timeout bound; no pre-roll handover |
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
| streamingInsertionEnabled | Persisted only / Persisted only | Mac allowlist is TextEdit and Notes; desktop inserts final text once |
| clipboardInsertionTriggers | Implemented, native acceptance pending / Implemented, native acceptance pending | General trigger entry; bounded native snapshot, canonical matching, no History re-expansion |
| enableSendToMac | Partial / Partial | iCloud web History sync is not Send-to-Mac transport/pairing |
| enableAutomationServer | Equivalent / Source wired, unqualified | Automation; Windows per-user named pipe unchanged, still saved as legacy `automationEnabled`; General switch plus source-only CLI and MCP setup dialog (status, pipe name, consent text, copyable `speak`/MCP/Claude Code text). Linux native opt-in starts a bounded same-user Unix socket and `speak`; imported/legacy true preserves intent but never grants device-local approval. False revokes. No native/runtime qualification claimed. |
| pasteRemoteTranscriptsAtCursor | Source wired, unqualified / Same | Shared arrival rule on synced History; 300 s poll and Mac-container-only limits |
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
| customShortcutBindings | Complete source mapping; unqualified / Partial window-local source | Windows Keyboard **Action shortcuts** dialog: all 27 actions source-wired; presets, Reset, duplicate/dictation refusal and RegisterHotKey failure reporting. Voice editing additionally requires an editable UIA selection and a rewrite API key. Linux projects 25 actions into window-local bindings and edits all saved bindings with presets/reset; selected-text speech, voice editing and global registration remain unimplemented. Native/physical acceptance pending. |
| paidAccessRoutingEnabled | Apple-specific / Apple-specific | BYOK desktop providers; no paid-access entitlement/routing journey. Retained opaque through import/export |
| simpleModelChoices | Missing / Missing | Native catalogue picker without simplified paid-model chooser |
| rememberedLocalTranscriptionSource | Partial / Partial | Models remembers Local selection; no Apple on-device source |
| rememberedRemoteTranscriptionMode | Equivalent / Equivalent | Models; native source/mode preferences |
| analyticsEnabled | Wired; nothing to gate / Same | General switch, Mac default and strict transfer. Desktop sends no analytics or crash reports; absent is never consent |

## Beyond the enum and destinations

The native global custom prompt reaches the shared cleanup policy, but
`postProcessingSystemPrompt` is not a current Mac persisted scalar or
`PromptStore` owner. Mac custom prompts live in profile `polishPrompt` records;
an actually present legacy desktop scalar is a distinct opt-in captured source,
not silently mapped to a profile. `customShortcutBindings`/individual action
shortcuts, Shortcut presets/reset and conflict reporting are source wired on
Windows (partial; see [Individual action shortcuts](#individual-action-shortcuts))
and partially window-local on Linux, with a source-wired editor and presets;
Linux global registration remains a gap. Escape recording cancellation remains a gap.
Profiles have a Windows native editor with
shared ordering/session snapshots; this separate source-only candidate adds
the GTK editor and actual recording selection described above. Apple bundle-ID matchers are preserved but
not silently converted to executable paths.

The Mac's 12 `SettingsTab` destinations are General, Transcription,
Post-processing, Profiles, Voice Output, Pronunciation, API Keys, Keyboard,
Permissions, Compare Models, Data & Migration and About
(`Sources/SpeakApp/Views/Settings/SettingsTab.swift:3-15`). Native desktops expose
General/Transcription/Post-processing/Voice Output/Keyboard/About and iCloud sync;
Windows also exposes Profiles and a separate native Permissions window (About, or
the setup guide); Linux has a passive Permissions guidance window in About,
and the GTK Profiles destination is added by this
unqualified source-only candidate. Both desktops now have dedicated API Keys windows
(see "API Keys pages" above; source only, NOT_RUN), sharing the same store as
their embedded provider controls. Comparison is implemented as a
separate native window outside this `SettingsTab` list — live/file multi-model
capture, blind judging/ranking, playback and scoreboard export
(`DesktopHostComparison.swift`, `WindowsComparison.swift`,
`LinuxComparison.swift`'s `jsti_comparison_present`) — not a missing journey;
it has portable test coverage but no native device/CI acceptance evidence
captured in this document. No dedicated `SettingsTab`-equivalent Pronunciation or
Corrections page exists on native desktops; Desktop's separate `DesktopVocabulary`/
`WindowsVocabulary` editor window already provides an equivalent lexicon, pronunciation.json
CRUD and auto-correction candidate review journey, reused from Read aloud/Generate above — not
a missing journey, just not a `SettingsTab` destination. Windows permission
troubleshooting/remediation is source wired (see first-run setup and permissions above); Linux
system-level permission changes and full archive migration remain unqualified journeys; Linux profile editing still needs
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

## Automation CLI and MCP setup (Windows, source only)

Command inventory: the shared `AutomationCommand` set (status, transcribe_file,
start_dictation, stop_dictation, get_history) is implemented by
`WindowsAutomationHost`; the compiler enforces every `AutomationCommandHost`
requirement, so no Mac command is missing from the Windows pipe. Mac App
Intents/Shortcuts (`AutomationIntents.swift`, `AutomationIntentSupport.swift`)
are Apple-only and have no Windows host surface.

General gains **CLI and MCP setup…** (`WindowsAutomationSettings.cpp`), the
counterpart of the Mac Automation and CLI cards. It shows on/off with the
per-user pipe name, the Mac's consent text, PowerShell `speak` examples, the
MCP client configuration and the Claude Code command, each with Copy. The text
comes from the shared `AutomationClientSetup` (`WindowsAutomationSetup.swift`),
so the MCP entry and commands match the Mac. The dialog's on/off button emits
the existing `AUTOMATION_TOGGLED` event; the pipe's owner-only DACL, remote and
lower-integrity refusal and default-off gating are unchanged.

`speak.exe` is already built for Windows (`Package.swift`) and ships beside
`SpeakWindows.exe`; the MSIX declares the console alias
`JustSpeakToItDeveloperCLI.exe`. The dialog finds whichever applies
(`jsti_automation_cli_path`) and a package test ties the alias to it. Gaps: no
`speak` name on PATH (the portable bundle changes no PATH; the alias name is
deliberately not `speak.exe`), no Mac-style CLI installer or "Copy PATH
command", and Windows still persists the legacy `automationEnabled` switch
rather than Linux's shared `enableAutomationServer` + device-local consent.

OpenClaw remains blocked: macOS has no OpenClaw settings journey to match, and
the client (`OpenClawClient*.swift`) is Apple-only, using
`URLSessionWebSocketTask`/os.log, with its conversation UI only in SpeakiOS.
Windows would need an injected WinHTTP WebSocket transport like the realtime
clients plus a native UI. The package alias test passed locally; native
execution and the dialog self-test are **NOT_RUN** here.

## Individual action shortcuts

Windows: source wiring, unqualified. Linux: partial window-local source wiring. macOS
behaviour, its `customShortcutBindings` key and its JSON shape are unchanged.

`DesktopShortcutAction` (SpeakCore) mirrors the Mac's 27 `ShortcutAction` raw
values, defaults and global eligibility; `DesktopShortcutCatalogParityTests`
asserts identical identifiers and defaults against the Apple types. Bindings keep
the Mac's `keyCode`, `modifiers` (`command`, `option`, `control`, `shift`,
`function`), `isGlobal` and `isEnabled` fields, so a desktop JSON configuration
export/import carries them under the Mac key and unknown entries survive.
`DesktopHostShortcutBindings` stores them in portable settings and the desktop
editor check (`DesktopShortcutBindings.editing`) is shared, not Windows-owned.

Modifier mapping: Command is Ctrl, Option is Alt, Shift is Shift. Mac Control,
and Fn on keys other than function keys, have no Windows equivalent: those
bindings are kept untouched for the Mac (an unchanged row keeps its stored Mac
binding even when its switches change) but are not registered on Windows.

Windows runs Start/Stop Recording, Pause/Resume (the active speech),
Stop speech through the Host without page/History-row gating, and the page
actions Dashboard, History, Voice Output
(both), General, Transcription, Post-processing, Corrections, Pronunciation,
Profiles, Keyboard and About. Data & Migration shows General, which holds the
Windows backup, export and inspection controls; API Keys, Permissions and
Compare Models press the All API keys, Permissions and Compare models buttons
when enabled; Quick Voice 1-3 select the saved favourite in that slot through the
shared Host action; Paste Last History Item delivers the newest History item
(regardless of filters or selection) with the saved text-output settings. Speak
Selected Text and Speak Clipboard read their own captured source through the
existing Voice Output pipeline. Troubleshooting opens the local configuration
and permission report. Edit Selection by Voice has a source-wired Windows
adapter; all 27 shared actions now have native execution mappings. This is
not a claim of compiled, installed or physically exercised shortcut parity.
Start/Stop Recording, Paste Last History Item, Speak Selected Text and Speak
Clipboard and Edit Selection by Voice can work in other apps (`RegisterHotKey`, which needs
Ctrl or Alt, or F13-F24 alone); other actions work while the window has focus. Global registration that Windows or
another app refuses is reported in the dialog and status line, and that shortcut
falls back to this window. Typing in text fields, list/combo navigation and
button activation keep their keys.

Pause/Resume TTS now targets the exact active speech handle on both desktop
hosts, independently of the selected History row. It applies to History Read
aloud, captured clipboard/selection speech and generated voice playback,
including the silent interval before or between segments. It does not start
or pause a History recording as a fallback. Native admission checks the full
speech identity under the playback lock, so a replaced/ended speech cannot
pause a newer speech or History run with the same record ID. Existing
record-bound History Play/Pause behavior is unchanged.

The Keyboard page's **Action shortcuts…** dialog lists every action with its
state, edits the key with Clear, Enabled and Works in other apps, offers the
presets Standard (defaults), Recording and speech only, and All action shortcuts
off, and **Reset to defaults**. Save refuses duplicates among enabled runnable
actions when either row was edited, the dictation shortcut's combination,
combinations the Mac cannot store, and keys without Ctrl, Alt or Shift other
than F13-F20 and Insert; it warns about system-reserved combinations and about sidebar `Ctrl+number`
chords, which run first. Most Mac page defaults (Command+digit) map onto those
sidebar chords, so their row notes say the sidebar handles them. An imported
duplicate that the user did not edit is not refused.

Linux now projects the shared key table to GDK/X11 key values without loading a
native framework into SpeakCore. Its Keyboard page shows every canonical
action, the saved combination and an explicit availability/scope note. There
are 24 window-local execution mappings: recording; Stop speech; Pause/Resume TTS;
Speak Clipboard; API Keys; Permissions; Dashboard,
History, Voice Output (both), General, Transcription, Post-processing,
Corrections, Pronunciation, Profiles, Keyboard and About; Data & Migration
(General); Troubleshooting; Compare Models; and Quick Voice 1-3. The actual
buttons' sensitivity and page availability still apply. Quick Voice queues
only the existing bounded Host settings action; it does not start synthesis.

Speak Clipboard admits the existing owned `readClipboardAloud` task; the
settings queue does not wait for clipboard capture, synthesis or playback.
It uses Linux's guarded native clipboard snapshot, not the selected History
record. Empty, non-text, failed or timed-out capture cannot fall back to History.
Stop, replacement, recording and shutdown cancel the owned speech request.
The shortcut is window-local and requires an idle, sensitive main window;
no global registration or external selected-text capability is implied.

GTK handles actions after focused controls and the existing sidebar shortcuts.
Text editors and editable/drop-down controls retain their keys. Matching
ignores lock state but not extra Ctrl/Alt/Shift/Super/Meta/Hyper modifiers.
The current keyboard layout supplies the unshifted key value for combinations
with shifted punctuation; AltGr-consumed Ctrl/Alt is not treated as an action.
Repeated presses of an admitted physical key do not repeat the action, even
while its native control is temporarily disabled. Key release is observed in
capture phase, and deactivation clears held keys. Modal/non-active windows do
not run local actions. An imported duplicate retains its value and shows a
conflict note; the first listed action owns that combination. Sidebar
Ctrl+digit chords retain precedence and corresponding action notes disclose it.

Three Linux actions remain unavailable: Speak Selected Text,
Paste Last History Item and Edit Selection by Voice. The Permissions action
opens its own Linux-specific recovery guidance, not an unrelated page.
Enabled global bindings remain saved and visibly unregistered;
they are not silently downgraded to local shortcuts. The existing single X11 /
Wayland-portal dictation shortcut is unchanged. Multi-action global registration
remains build-out work. Because this is only
partial application of `customShortcutBindings`, migration continues to
preserve the whole value rather than claiming full Linux coverage.

The Linux Keyboard **Edit action shortcuts...** dialog edits a draft with
native key capture, Clear, Enabled and Work in other apps switches. It uses the
same canonical presets and reset defaults as macOS/Windows. Global switches
explicitly say the binding is saved but not registered. The shared editor
validation refuses newly introduced duplicates, unmodified typing keys and
local collisions with Linux's separate Ctrl+Alt+Space dictation shortcut;
sidebar collisions and shared reserved-key policy produce visible warnings.
Restoring canonical defaults explicitly permits the default Space/Escape media
keys without permitting arbitrary unmodified typing keys.

Record-key mode protects keyboard focus; Escape cancels recording a key and
Tab can leave that mode. The main window's dictation gesture/command admission
is suppressed while this editor is open, without dropping releases from a
gesture already in progress. Save/Cancel and error feedback remain visible
outside the scrolling form. Mac-only combinations survive switch-only edits;
explicit Clear is distinct from an unsupported key. Unknown future entries
survive edits and presets. An unchanged settings refresh keeps the draft's
revision; changed saved bindings invalidate it. Host persistence compares
against the original bindings again after queue admission. A failed write
leaves memory, disk and draft unchanged, and a request-correlated completion
prevents a late save result from closing a newer editor. Saving is not reported
as complete until persistence and native reconfiguration have succeeded.

Evidence: portable tests in
`Tests/SpeakCoreTests/DesktopShortcutCatalogTests.swift` and
`Tests/SpeakDesktopHostTests/DesktopHostShortcutBindingsTests.swift`; four new
`DesktopShortcutLinuxChordTests` regressions cover every canonical key, exact
GDK values, modifier policy and unchanged stored bindings. Linux's no-device
self-test checks all 27 action execution dispositions; the GTK smoke fixture
checks displayed rows/availability, case/lock normalization, extra modifiers,
typing focus, disabled rows, key release/repeat suppression and invalid inputs.
Native dispatch fixtures exercise actual page navigation, record/Stop events,
all three Quick Voice slots, and busy/disabled-window/control refusals without
calling a capture device or speech provider.
The native dispatch fixture also checks Speak Clipboard and speech-pause admission and
busy/disabled-window refusal. Existing captured-source Host regressions cover
clipboard-versus-History ownership, empty/non-text input and cancellation;
they are not evidence that this new Linux mapping has run.
New Host speech-pause regressions cover captured sources while an unrelated
History row is selected, absent speech and post-Stop refusal. Linux and Windows
playback regressions exercise exact-handle pause/resume, stale handles with a
reused record ID and refusal to affect History playback. Existing segment
tests additionally use the new speech-handle entry point. A Windows native
dispatch fixture distinguishes the speech shortcut event from History Play.
These additions are source-only and NOT_RUN.
Six `DesktopHostLinuxShortcutEditTests` cover switch-only preservation versus
Clear, every preset/default, invalid/duplicate keys, strict complete draft
decoding, stale saves and refused writes. GTK editor fixtures cover draft
isolation, key capture, Clear, presets/reset, visible failed saves, UUID case
normalization, close/reopen late-result fencing and stale configurations.
These new checks, compiler, native smoke tests and physical keyboard acceptance
are **NOT_RUN** for this source.

### Edit Selection by Voice: Windows source implementation, unqualified

The Windows action captures the foreground field synchronously at the shortcut,
before queuing host admission. One press captures the selection and starts
private instruction recording; a second finishes, transcribes the raw instruction
and requests the same dedicated rewrite prompt and intent-aware formatting policy
as macOS. Ordinary cleanup may remain disabled. Cleanup-only local models use the
canonical cloud rewrite default instead, with its own required API key. Model,
temperature, transcription credential, rewrite credential and profile are captured
for the run. A normal dictation press cannot steal its microphone.

The Windows adapter retains a UIA selection range, selected text and bounded full
document. Before delivery and again immediately before mutation, all must still
match the original process, window, field and focus revision. Identical text
selected elsewhere is not the same anchor. Replacement is verified against the
expected complete document, preserving whitespace and Unicode apart from native
newline encoding. This route cannot redirect to another app or use replace-all.
An unverifiable anchor yields an explicitly explained clipboard recovery, not
automatic typing somewhere else. Ambiguous dispatch is never replayed; cancellation
abandons the target and suppresses clipboard recovery.
The existing native HUD distinguishes confirmed replacement from recovery or error;
manual paste is not shown as a successfully completed edit.

Instruction audio is temporary, private and absent from History. Capture stop,
destroy, busy ownership and scratch cleanup are shared across finish, Cancel and
close; provider work is separately counted, and late replies cannot replace text.
A cancelled provider that has not returned retains its private scratch directory
until its last worker exits. New runs use the versioned `VoiceEdit-v2` namespace:
a native cross-process directory lease excludes another controller/app instance,
including while a cancelled provider still owns audio. Startup (or first use)
removes abandoned UUID runs only after acquiring that lease. Native cleanup
accepts only an empty run or its single `instruction.wav`; links, extra entries,
hard-linked audio and unsafe directories are refused rather than recursively
deleted. Failures are reported. Legacy `VoiceEdit` directories are reported, not
swept: they have no lease provenance and require separate explicit remediation.

Authored evidence: `DesktopVoiceEditTests`, `VoiceEditPolicyTests`,
`DesktopHostVoiceEditTests`, `DesktopVoiceEditScratchTests` and the real RichEdit/UIA voice-edit anchor fixture
inside `jsti_text_output_self_test`. These cover client policy, batch/live host
orchestration, missing input/credentials, normal-dictation exclusion, capture
failures, cancellation/restart/close, private-file removal and changed native
anchors, including a range move immediately before paste dispatch. They are
supplemented by native scratch-owner exclusion, released-owner recovery,
extra-entry preservation, failed-initialization lease release, POSIX link refusal
and a host close with an uncooperative rewrite still holding its lease.
**NOT_RUN** locally. Automatic compiler/test qualification, installed-app keyboard
and provider/device acceptance remain outstanding. Linux has the shared host
implementation but no selection-anchor adapter or shortcut registration.
