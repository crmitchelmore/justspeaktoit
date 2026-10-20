# Linux development

The Linux target is a **developer preview, not a Linux release**. It reuses the
portable Swift core (`SpeakCore`, `SpeakDesktop`) and the desktop host shared
with Windows (`SpeakDesktopHost`), and reaches the desktop through a narrow C
adapter (`CLinuxSupport`) over GTK 4/libadwaita, libpulse, libsecret, X11/XTest
and the XDG desktop portals. Feature parity with macOS remains the acceptance
criterion; this document says exactly what is verified and what is not.

## Layout

| Target | Role |
|---|---|
| `SpeakDesktopHost` | Recording, transcription, History, output, post-processing, profiles, model catalogue, Read aloud, on-device model and iCloud sync orchestration, generic over `DesktopHostPlatform`. Shared with Windows (moved out of `SpeakWindows`). |
| `CLinuxSystem/*` | pkg-config system libraries: `libadwaita-1`, `gio-unix-2.0`, `libpulse`, `libsecret-1`, `xtst`, `libcrypto` (OpenSSL). |
| `CLinuxSupport` | The `jsti_*` C ABI (`include/CLinuxSupport.h`): window, clipboard, credentials, capture, private files, X11, portals, the whisper.cpp loader and GChecksum SHA-256, iCloud sync (group, loopback listener, sign-in page, envelope crypto), self-tests. |
| `SpeakLinuxPlatform` | Testable Swift over the C ABI: keyring, capture, session detection, text-output options, output planning, the output job, History playback and speech, voice output staging, and the iCloud sync adapters. |
| `SpeakLinux` | The executable: `LinuxHostPlatform`, events, shortcuts, `--self-test`, `--ui-smoke-test`, `--integration-test`. |

The Linux targets are opt-in with `SPEAK_LINUX_TARGET=1`, like
`SPEAK_WINDOWS_TARGET=1`, so the `portable-linux` job (which has no GTK
packages) is unchanged.

Gemini Transcribe Live, Meta Muse realtime ASR and Modulate Velma now use the
shared injected provider clients through Linux's NIO WebSocket adapter, with
the same canonical route/options projection as Windows. Audio is bounded and
single-flight, readiness is provider-specific, and a finish without the
documented terminal event is an error, not a successful recovered transcript.
The native NIO loopback probe suite checks generated PCM, production request
shapes, completion and early closure for these clients and the portable Grok
Voice client. Grok Voice remains unavailable for selection until a live
transcription-only/no-assistant service acceptance receipt exists. Synthetic
transport evidence does not establish provider-account or hardware parity;
see [Windows shared streaming details](windows-development.md).

The shared desktop live session uses macOS's canonical authoritative transcript
projection for replacement, empty retraction, confirmed/interim composition and
healthy final folding. Cancelled or failed sessions keep recovery text and
ignore late projections. Providers without projected text retain legacy folding.
This does not implement clipboard voice commands or live LLM polishing.

## Build and run

Voice Output also offers a native text editor, explicit clipboard snapshots and
user-chosen lossless WAV export. See [Desktop Voice Output sources](desktop-voice-sources.md)
for source ownership and honest external-selection/Wayland capability limits.

Ubuntu 24.04 (or any distribution with GTK 4.14+, libadwaita 1.5+) and Swift 6.2.3:

```sh
sudo apt install g++ libgtk-4-dev libadwaita-1-dev libpulse-dev libsecret-1-dev \
  libx11-dev libxtst-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good gstreamer1.0-libav libssl-dev pkg-config
export SPEAK_LINUX_TARGET=1
swift build --product SpeakLinux
swift test                                  # portable, host and Linux tests
.build/debug/SpeakLinux --self-test
scripts/linux-desktop-checks.sh             # self-test + Xvfb window smoke test
scripts/linux-integration-checks.sh         # keyring, PipeWire, portals, X11 paste
.build/debug/SpeakLinux                     # the app
```

Portable builds also compile the in-process local-model C++ adapter. They need
the C++ standard-library development headers and linker files supplied by `g++`,
even when no downloaded model or inference runtime is installed.

The smoke test needs `xvfb` and `dbus`; the integration checks also need
`gnome-keyring pipewire pipewire-pulse wireplumber pulseaudio-utils openbox
zenity xdotool python3-gi`. Set `JSTI_UI_SNAPSHOT_PATH=/tmp/window.png` to save
a picture of the smoke-test window.

`SpeakLinux --ui-screenshots <folder>` opens a throwaway window over the shared
sample History (`DesktopHostSampleHistory`, the transcripts the Mac's website
screenshots use), visits every page and saves each one twice, as the visible
window and as the whole scrolled page (`NN-name.png`, `NN-name-full.png`),
then the dashboard and History in dark mode and the dashboard while recording.
`scripts/linux-desktop-checks.sh` runs it when `JSTI_UI_SCREENSHOT_DIR` is set,
and CI uploads the pictures as `linux-ui-screenshots`.

Recording feedback uses a dedicated, warmed libpulse channel and the bundled
AAC cues. `SpeakLinux --self-test` decodes all eight cues with the production
GStreamer path; missing codecs or resource bundles fail explicitly.
`SpeakLinux --recording-feedback-self-test` requires a real Pulse endpoint and
checks both cues for every profile, reusable stop and joined close. It reports
first-buffer queue admission (at most 100 ms), not audible hardware latency.
The integration script runs this against its private PipeWire null sink.
An installed package must pass `--self-test` as well; a source-tree pass does
not establish resource placement or codec availability in a Flatpak runtime.

### Local automation (`speak`)

Source wiring, authored synthetic regressions and packaging are present; this
integration successor has **not** been compiled, tested, linked or run. This is
not native or feature-parity qualification.

Build `speak` with `swift build --product speak` alongside the app. The native
General > Automation switch is off by default. Explicitly enabling **Allow local
automation** grants access on this computer; the subtitle reports actual listener
readiness or failure, not just the saved request. Imported or upgraded
`enableAutomationServer=true` (including legacy `automationEnabled=true`) is
preserved as requested intent but cannot grant approval. Imported false and local
disable stop access; a failed revocation save explicitly warns that restart may
restore the previous saved grant. Export never transfers local approval. This
permission is independent of Auto-Clean approval.

The existing CLI grammar is reused: `speak status --json`, `speak history`,
`speak transcribe <file>`, and `speak listen` / `speak stop`. Consult `speak --help`
for supported options; language flags are not invented. File transcription uses
the selected canonical batch/profile snapshot and the normal preparation and
inference adapters, without creating History, inserting text, reading the
clipboard or authorizing post-processing. The caller's input remains unchanged;
transient conversion cleanup failures are errors, not successful read-only
results. Start/stop use current captured-profile recording/live/finalization and
History pathways. No focus target is manufactured: Wayland capabilities and
unsupported-output errors remain real. The existing `--toggle` journey remains.

`CLinuxAutomation` owns a private user-owned 0700 endpoint directory and 0600
socket, authenticates same-user peers using `SO_PEERCRED`, rejects linked,
foreign-owned or insecure paths and refuses existing competing endpoints. The
default is below `XDG_RUNTIME_DIR`, or a private train/user directory below
`/tmp`; `SPEAK_AUTOMATION_SOCKET` overrides both client and server paths subject
to the same checks. It never changes shared-parent permissions, the process
umask or signal handlers. Socket cleanup checks the retained directory and
device/inode identity; it preserves observed replacements. Linux has no atomic
compare-and-unlink namespace operation: uncooperative concurrent same-user
namespace mutation is not claimed to be atomically protected.

Frames, connections (four), replay/in-flight work and actual I/O deadlines are
bounded. Shutdown interrupts and joins owned transport workers off GTK and the
settings executor; long commands are separately cancellable Host work.
Control-plane socket I/O is not part of capture, inference or insertion.
`stage-linux-desktop.py --cli <built-speak>` stages the CLI without changing the
existing local-runtime staging contract. Flatpak builds/stages `speak` inside
its sandbox; cross-sandbox host access is not established by this source.

### Canonical application icons

The Linux application uses the canonical Mac icon exports, not a separately
drawn approximation. `scripts/generate-icon.swift` invokes the dependency-free
`scripts/generate-desktop-icons.py`, producing a private hicolor theme with
16, 24, 32, 48, 64, 128, 256 and 512px PNGs and transparent corners. SwiftPM
bundles that theme in `SpeakApp_SpeakLinux.resources`; it is loaded via
`Bundle.module`, not the current working directory. GTK sets the window icon
name to the desktop entry's `com.justspeaktoit.JustSpeakToIt`. The in-app brand
marks and StatusNotifier pixmaps read the same artwork; panel exports include
64/96px variants and preserve the recording dot. The coloured app icon is
identical in light/dark themes, not a symbolic icon; Wayland compositors use
the matching application/desktop identity rather than a client-supplied
title-bar bitmap.

Flatpak ships both the private runtime theme and installed hicolor PNGs.
For a native developer layout, stage (do not install) the executable, resource
bundles, desktop entry, metainfo and icons with:

```sh
python3 scripts/stage-linux-desktop.py --binary .build/release/SpeakLinux \
  --output .build/linux-desktop-layout --prefix /usr/local
```

The output contains `bin/` and `share/`, intended for the stated prefix.
It still requires the matching Swift/native libraries; this is not a
self-contained Linux release. The stager never changes the running system and
refuses an existing output directory. Installed icons do not overwrite the
system hicolor `index.theme`; the private bundle retains its own index.
The stager collects every non-test sibling `.resources` bundle, including future
production modules, while still requiring the core and Linux icon bundles.
Linked bundles, linked entries and non-regular resource content are refused
before creating output. Flatpak uses this same stager with `/app` as its prefix
instead of maintaining a separate resource list.
Spaces, quotes, backslashes, dollar signs and backticks in prefixes use the two
Desktop Entry escaping layers. Percent/equal-sign prefixes are refused before
writing because they are not portable executable paths for desktop launchers.

`python3 scripts/generate-desktop-icons.py --check` verifies exact exports;
`python3 -B -m unittest discover -s scripts/tests -p test_desktop_icons.py`
checks native resource wiring and a synthetic staged layout. The GTK window
self-test requires the canonical name to resolve in the theme. The Python
checks are not proof of GTK/Wayland/panel rendering or an installed Flatpak;
those remain native CI and desktop validation gates.

## Model comparison

**Transcription > Compare Models** opens a native GTK/libadwaita editor with
wrapped, accessibly named model checkboxes, File/Batch and Live input modes,
language hint, saved rounds, raw blind results, ranking/reveal, scoreboard,
sample playback and JSON/Markdown exports. File selection accepts one or more
local samples without a sample-count ceiling; save dialogs use the desktop's native
file chooser. Picker errors appear in the comparison editor instead of being hidden
behind its modal window.
The export scope chooses **All rounds** or **Selected round** for both
**Save JSON / Markdown** and explicit **Copy JSON / Markdown**. Save requests
freeze the selected round when the chooser opens, independently of later
selection changes; a deleted/missing round is an error, never an all-round fallback.
Clipboard export does not insert text or mutate normal History.
Closing a picker/editor invalidates that picker request, so a late selection
cannot start a replacement editor's run.

Windows and Linux share `DesktopComparisonRunner`, `DesktopComparisonLive`,
`DesktopComparisonStore` and `DesktopHostComparison`: all file snapshots are
prepared before provider work, one native microphone capture fans out to the
qualified live routes, and raw results never reach insertion, post-processing,
dictation settings or normal History. Failed candidates remain independently
judgeable. Complete distinct ranks 1...N reveal models; canonical persisted
rounds determine standings and exports.
Fewer than two usable results reveal unranked evidence, matching Mac, rather than
inventing rankings or scoreboard credit. See the
[Windows comparison workflow](windows-development.md#model-comparison) for the
shared 120-second file, 12-second readiness and 30-second finalization budgets.
Native **Select all ready / Select none** and remembered per-mode candidate
selection use canonical credential readiness plus local-runtime/Azure endpoint
checks. Unavailable qualified models have explicit reasons in the detail pane;
their saved selections survive ready-only edits and relaunch. Credential writes,
cloud-key imports and endpoint changes refresh readiness. Keys/settings are read
again after the final admission suspension, before audio/provider work, and
admitted runs keep immutable snapshots. Readiness does not validate a key with
the real service. Cancel/editor close invalidates pending admission across
editor reopen.
`DesktopSettingsQueue` admits File/Live work without waiting for playback:
separately owned admission tasks are cancelled on Cancel/editor close/shutdown.
Batch freezes all sample/model/language snapshots before its first request and
pauses after each round for judging. Saving ranks only reveals: **Next file** must
explicitly start the next sample, including after an unranked failure reveal.
Queued rounds retain sync/deletion leases. Cancel, discarding the current round,
editor close and shutdown retain recovery evidence but never resume requests on
relaunch. File/Batch has no model-count ceiling and uses a sliding set of at most
eight underlying provider operations. Deadlines/cancellation do not release an
uncooperative operation's slot, audio lease or accounted bytes before actual exit;
exhausted capacity is an explicit error, not replacement admission. Close does not
join those operations. Sync and local deletion cannot remove their samples.
Preflight and incremental accounting bound newly owned staged audio plus canonical
revision metadata to 800,000,000 bytes, with a separate single 25,000,000-byte scratch
slot and serial preparation. Unused reservations roll back; queued/still-running
operations retain theirs. See the Windows workflow for the common ownership policy.
This bounds active staging ownership, not the lifetime size of persisted comparison history.
The staging budget is a deliberate resource limit, not Mac equivalence or hardware
acceptance. Per-file import/conversion remains 25 MB versus Mac comparison's 100 MiB.
Live still admits two to eight simultaneous lanes; no waves or replay stand in for
live comparison.
A blind **Diff against** dropdown uses the shared
`TranscriptWordDiff`, with accessible `[+added]` / `[-removed]` text annotations
instead of colour-only edits; original transcripts and persisted ranks stay unchanged.

`Comparisons/rounds.json` and app-owned `Comparisons/Samples/` live in the private
data directory. Interrupted rounds retain their audio; interrupted live metadata
can remain unknown until normal finalization. Native confirmed delete/discard
persists a canonical tombstone before cleaning up its app-owned sample, while
startup prunes orphan samples. Original imports and normal History are untouched.
The shared comparison capture safety limit is 600 seconds, not an age/count
retention policy. The editor's separate explicit iCloud consent and **Sync now /
retry** use the same canonical, account/consent-fenced metadata-only comparison
sync as Windows. Sign in from the existing iCloud Sync settings; local changes,
manual retry and the existing 300-second web heartbeat reconcile rounds and
tombstones. Comparison owns a separate cursor/acknowledgements and preserves
original-account provenance. Active capture/queued batch revisions are excluded
and protected against remote deletion; remote metadata never supplies audio.
Automatic interrupted/failed provider retry is not a Mac comparison feature and
is not added here.
The GTK window self-test checks wrapped labels, model and language payloads,
ranking, playback, scoped export payloads, explicit sync consent/retry and
busy/recording controls with synthetic fixtures only.
The screenshot tour adds `comparison-blind-light.png` and
`comparison-revealed-dark.png`, plus `-full.png` views including the below-fold
ranking/export controls, without changing page ordinals. Native execution
at the final head, physical PulseAudio/PipeWire devices, screen-reader/keyboard
acceptance, small-screen behavior, live-provider and real-account CloudKit receipts are separate gates;
portable tests and syntax/type checks do not establish those gates.

## Window

The window follows the Mac app's layout and look. A sidebar lists **Speak**
(Dashboard, History, Voice Output) and **Settings** (General, Transcription,
Post-processing, Keyboard, Corrections, Pronunciation, iCloud Sync, About), and collapses to one pane below
640 px. The header carries Import audio, the page title with the selected model,
and Record; the status line sits at the bottom of every page.

- **Dashboard**: the brand-gradient hero with Start Recording, the words
  arriving while recording, and Sessions, Recording Time and Spend; the
  displayed transcript with Copy (and Cancel while transcribing); Insights
  (Sessions, Recording Time, Average Length, Spend) and a Setup card echoing the
  microphone, model, shortcut and text output.
- **History**: search, Filters and Import in the hero with Sessions, Errors, Average
  Length and Spend for the recordings the search shows; each recording is a card
  with Created, Audio, Cost and Context badges, the transcript preview and the
  models used. The selected card expands with its transcript, version, Play,
  Stop, Copy, Read aloud, Retry, Export and Open audio.
- **History filters**: the native GTK popover combines any recorded transcription
  or post-processing models, errors only, and optional From/Through calendar
  dates with the existing Unicode/profile search. Apply and Reset change only
  visibility; hidden selections stop playback and Read aloud. Dates use the
  shared `HistorySearchQuery` day policy in the local time zone. This does not
  add History deletion, retention, or migration. Long model names wrap without
  losing their full labels, and date buttons distinguish From/Through in their
  accessible names. The screenshot tour requires light/dark filter-popover
  artifacts; source assertions and snapshots do not replace physical accessibility
  acceptance.
- Totals and row wording come from the shared `DesktopHistoryInsights` and
  `DesktopHistoryRowSummary` (SpeakDesktop), counted and formatted as the Mac
  counts them, so Windows shows the same figures.
- Colours are the brand tokens in `SpeakCore/BrandColors.swift`; everything else
  follows libadwaita, so the window honours the desktop's light or dark style.
  **General › Appearance** overrides it (Follow the system, Light, Dark), saved
  as `appearance` in `settings.json` and shared with Windows.

The **recording HUD** (`LinuxHUD.c`) follows each dictation with the phases,
wording, clock and display times of the shared `DesktopHUDState`, as the Mac's
bottom-centre card does. On X11 it is an undecorated
`_NET_WM_WINDOW_TYPE_NOTIFICATION` window kept above others at the bottom
centre of the active window's monitor, with an empty input region, no input
focus (`WM_HINTS`) and a zero user time, so a paste still reaches the field
focused at the shortcut; it shows the microphone level and the latest live
words. Wayland lets no client place or raise its own window, and a new window
could take focus from that field, so there the HUD shows nothing while working
and a desktop notification reports the result when the app window is not
active. The window self-test checks the X11 properties and placement; the
screenshot tour saves `13-hud-recording.png` and `14-hud-completed.png`.

Where the desktop has a StatusNotifierWatcher (KDE Plasma, Ubuntu's GNOME
through the AppIndicator extension, Cinnamon, XFCE, Budgie and most panels),
a **status notifier** (`LinuxTray.c`) puts the brand icon in the panel, with a
red dot while recording, like the Mac's menu bar extra. Its
`com.canonical.dbusmenu` menu shows Ready, Recording or Transcribing and the
dashboard's Sessions, Recording Time and Spend, and offers Start or Stop
Recording (Cancel Transcription while working), Open, Settings and Quit;
activating the icon opens the window. It registers under the app's own bus
connection, so the Flatpak needs only `--talk-name=org.kde.StatusNotifierWatcher`.
Plain GNOME has no watcher, and then nothing is registered.

**General › Launch at login** (`LinuxLoginItem.swift`), like the Mac's login
item, starts the app minimised when the user signs in. Outside Flatpak the
switch writes and removes an XDG autostart entry,
`$XDG_CONFIG_HOME/autostart/com.justspeaktoit.JustSpeakToIt.desktop`, whose
`Exec` runs this executable with `--background`; the entry is the record, so
removing or disabling it in the desktop's startup settings (`Hidden=true`,
`X-GNOME-Autostart-enabled=false`) shows the switch off. The sandbox cannot see
that folder, so inside Flatpak the Background portal's `RequestBackground`
(`autostart`, the same command line) writes it, a refusal shows as off by the
desktop, and the state last granted is kept in `settings.json`. A launch with
`--background` creates the window minimised without asking for focus; a second
one leaves the running app alone.

A second invocation with `--toggle` starts or stops dictation in the running
app without raising its window (GApplication forwards the command line), so it
can be bound to a key in any desktop. The `app.toggle-recording` action does
the same over D-Bus.

The X11 listener discovers CapsLock/ShiftLock, NumLock and ScrollLock slots from
the actual modifier and key maps when registering, rather than assuming Mod2
and Mod5 are locks. A slot that also contains AltGr, a group-switch key or another
ordinary key is deliberately not ignored; explicitly required modifiers also
remain required. Grab and release use the same owned set of unique lock-state
variants, and event admission rejects extra non-lock modifiers. Custom maps with
mixed lock/non-lock slots may need the desktop-owned `--toggle` binding instead.
Runtime key/modifier remapping still needs a listener restart: automatic
remapping/rebinding, multiple global actions and real keyboard/layout acceptance
remain open gates. No-display native fixtures cover the classification and mask
invariants, including the 256-variant bound; these changes are NOT_RUN locally.
The disposable Xvfb integration harness also authors an
`--integration-test x11-hotkey-locks` check: reject Ctrl+Alt+Shift+Space, then
require exact press/release receipts with locks off, CapsLock, CapsLock+NumLock,
NumLock, and locks off again. Each producer phase waits for its own
acknowledgement; a false extra-modifier activation cannot compensate for a missed
lock-state action. Readiness, phase waits and the child process are bounded; native
stop is deferred on every exit. The rejection uses a 250 ms test-only quiet
window, not a production readiness delay. The private server is discarded after
the harness; no real desktop key map is modified. This check is NOT_RUN locally
and does not qualify AltGr, arbitrary layouts, runtime remapping or Wayland.

With the app **already running**, desktop keyboard settings can also bind
`justspeaktoit --speak-clipboard`, `justspeaktoit --speak-selected-text` and
`justspeaktoit --paste-last-history`.
The same running-app forwarding path supports `--stop-speech`,
`--pause-resume-speech`, and `--quick-voice-1`, `--quick-voice-2` or
`--quick-voice-3`. Quick Voice selects the corresponding saved favorite; it does
not start speech, record an instruction, or read selection/clipboard text.
Pause/Resume acts on the active speech through the existing Host policy.
Stop uses the existing Playback Stop action. Its native control remains enabled
while idle, recording or working; Stop is idempotent if no audio is playing.
It cancels speech/playback without cancelling dictation or clearing a busy
operation's state/status. Modal-disabled or closing windows still refuse it.
Inside Flatpak use `flatpak run com.justspeaktoit.JustSpeakToIt` followed by the
same argument. These commands forward without presenting the window, preserving
the external app's focus. Speak Clipboard uses the saved Voice Output settings;
Paste Last History captures the invocation target and uses saved output policy,
not the selected History row. Clipboard-only output requires no external field.
X11 requires a captured external window for paste; Wayland retains the existing
portal delivery-time-focus and recovery-copy behavior, not an anchored-field
guarantee. Forwarding happens before model/controller construction or opening
application stores. A cold invocation of any of these commands exits nonzero
instead of opening a window and acting on the wrong focus.

Choose one action per invocation; different action flags together or unsupported
options are refused before dispatch, including two different Quick Voice slots.
This preflight includes legacy `--toggle`: adding an unknown option (including
`--gapplication-service`) or another action refuses before model/controller
construction or store access. A valid `--toggle`, with optional `--background`
or repeated identical toggle flags, keeps its existing cold-launch and
running-app dictation behavior; it is not changed into a running-only command.
Busy/recording states refuse clipboard/selected-text speech, History paste, Pause/Resume and
Quick Voice; closing or modal-disabled windows refuse all commands. Stop follows
its own control's availability as described above. Refusal returns a nonzero exit
status. Status 0 means admitted
to the running app, not that speech or paste completed; results and provider
errors appear in the app.
Bindings remain user-owned desktop configuration: the saved Global switch
does not automatically register these actions. Parser and native dispatch
fixtures are authored but NOT_RUN locally.

Selected-text speech requires its own **Voice Output > Selection access >
Allow...** session disclosure. After allowing, refocus an external ordinary
editable AT-SPI field, select text and invoke `--speak-selected-text` without
raising this app. The selected text may be sent to the saved remote Voice
Output provider. Correction-learning consent does not authorize this read-only
session; neither settings nor imports grant it. Stop access revokes pending
reads before requesting speech Stop, and shutdown revokes access before draining
settings. The app does not enable desktop accessibility.

Capture on the command path uses only an already-admitted field receipt. A
single pending lease across session restarts prevents queued target accumulation.
The private worker has 2.5 seconds from invocation, requires exactly one
nonempty selection of at most 8,192 Unicode scalars / 32,768 UTF-8 bytes, and
rechecks target identity, privacy, range and contents before returning a
snapshot to the owned Host speech task. Selection/caret changes invalidate the
receipt; any new admission revalidates the same known control off the action
path. Text mutation events are registered only during the explicit read.
Read-only documents, password/ambiguous controls and unsupported apps refuse;
there is no clipboard or PRIMARY-selection fallback. This is a per-field
AT-SPI capability, not blanket X11/Wayland support. The in-app source dialog
still excludes external selection because opening it changes focus.
Pure contract and command fixtures are authored, NOT_RUN locally; real field,
provider/audio and compositor acceptance remain unverified.

`scripts/linux-desktop-checks.sh` also opts into a cross-process fixture only
inside its private session bus. It launches 39 real command-client processes
against the production native command handler with a synthetic event callback:
valid and repeated commands, `--background`, mixed action flags, unsupported
options, Quick Voice slot identity/conflicts, Stop availability during idle,
working and recording states, busy/recording/modal/closing refusal, and all eight running-only
commands with no primary. Malformed toggle options are additionally refused both
with and without a primary; no real toggle/provider action is delivered.
The fixture applies production `refresh_actions` for each state, not a synthetic
Stop-sensitivity override, including explicit Stop modal/closing refusals.
Each child has a 15-second deadline and is reaped; the smoke-test envelope is
600 seconds. The fixture requires exact callback identity/count/slot, unchanged page
and hidden-window visibility, refusal diagnostics, and an empty isolated data
directory after all clients. A separate smoke-window application path avoids
colliding with the fixture's real GApplication identity; a private main context
keeps unrelated GTK/Host callbacks out of the fixture. It never invokes providers,
reads clipboard content, or pastes into a field. This fixture is also NOT_RUN
locally: automatic cross-process qualification, compositor key bindings and
external-field/provider acceptance remain unverified.

Data lives in `$XDG_DATA_HOME/JustSpeakToIt` (`~/.local/share/JustSpeakToIt`;
Flatpak: `~/.var/app/com.justspeaktoit.JustSpeakToIt/data/JustSpeakToIt`):
`settings.json`, `History/`, profiles and the OpenRouter catalogue cache, all
private to the user (0700/0600). API keys are in the Secret Service keyring
under the same canonical identifiers as Windows Credential Manager. iCloud
sync keeps its state in `CloudSync/state.json` there (see below).

### Vocabulary and pronunciation

The **Corrections** and **Pronunciation** pages use real GTK entries, multiline
variant/preview fields, dropdowns, check buttons and filtered saved-entry lists.
Both support durable editing, deletion confirmation, explicit ordering,
validation and saved-entry preview; pronunciation also supports canonical
defaults and local JSON merge/replace/import/export. **History > Correction
results** shows the retained applied corrections, unapplied suggestions,
confidence, reasons and context in a native read-only scrolling dialog.

Windows and Linux use the same portable domain/store machinery and apply
corrections at recording/import/retry/live-finalisation before post-processing,
without replacing the original provider transcript. Read aloud runs the
canonical pronunciation replacement renderer once before segmenting expanded
text to Deepgram's request limit. IPA-only entries are retained but not claimed
as supported by Deepgram. Context tags are explicit input; there is no OS-wide
edit observation, permission request or fabricated learning. Candidate
management logic is shared, but a desktop candidate-management UI is not yet
implemented. Data remains in the existing private XDG application directory.

See [the shared desktop journey](windows-development.md#vocabulary-and-pronunciation-journey)
for rule semantics, storage files, supported provider hints and remaining
physical/native acceptance. Native syntax checks and synthetic form-event
self-tests do not replace target-platform runtime evidence.

### Flatpak

`packaging/linux/com.justspeaktoit.JustSpeakToIt.yml` builds with the GNOME 50
runtime (GNOME 48 reached end of life in March 2026) and the Flathub
`org.freedesktop.Sdk.Extension.swift6` extension, currently Swift 6.3.3 on the
25.08 branch, with `--static-swift-stdlib` (checked locally: the release binary links no Swift
libraries and passes `--self-test`; static FoundationNetworking needs libcurl
headers, which the GNOME SDK has). The desktop file and metainfo pass
`desktop-file-validate` and `appstreamcli validate`.

```sh
flatpak-builder --user --install --force-clean build-dir \
  packaging/linux/com.justspeaktoit.JustSpeakToIt.yml
flatpak run com.justspeaktoit.JustSpeakToIt
flatpak run com.justspeaktoit.JustSpeakToIt --toggle
```

`flatpak-builder` has built this manifest on GNOME 48 (Swift 6.2) and GNOME 50
(Swift 6.3.3); inside the resulting build environment `--self-test` and the
Xvfb `--ui-smoke-test` passed. iCloud sync has since added a link to
`libcrypto` (OpenSSL), which the freedesktop SDK under the GNOME SDK ships;
no Flatpak has been built with it yet. Not yet done: an installed `flatpak run` on a
desktop, a `.flatpak` bundle in CI, and Flathub readiness.

The root `Package.resolved` pins the Apple graph, which the Linux graph does not
match. `packaging/linux/Package.resolved` pins the Linux graph (SwiftNIO,
NIOSSL, swift-atomics, swift-collections, swift-system). CI and the Flatpak
manifest copy it into place and build with `--force-resolved-versions`, so a
pin that no longer satisfies `Package.swift` fails the build instead of
floating, and CI also fails if the build rewrites the pins. After changing the
Linux dependencies, regenerate it with
`SPEAK_LINUX_TARGET=1 swift package resolve`, copy `Package.resolved` to
`packaging/linux/`, and restore the root file. The Flatpak build still fetches
those pins with network access (`build-args: --share=network`); Flathub builds
offline, so a submission must also list them as git sources.

## Desktop support

| Desktop (2026) | Shortcut | Paste into the focused app | Fallback |
|---|---|---|---|
| GNOME 48+ Wayland | GlobalShortcuts portal (asks once) | RemoteDesktop portal, keyboard only, persist mode 2, restore token in the keyring; transcript offered through the Clipboard portal; Ctrl+V as keysyms | Copied + notification "press Ctrl+V" |
| KDE Plasma 6 Wayland | GlobalShortcuts portal | Same portal path | Same |
| Hyprland | Portal (xdg-desktop-portal-hyprland) | Portal path if its RemoteDesktop is available | Copy |
| Sway, niri, other wlroots | No portal: bind `justspeaktoit --toggle` | No RemoteDesktop portal: copy | Copy |
| COSMIC | Portal or `--toggle` binding | Portal path (restore tokens reported not to persist) | Copy |
| X11 (any) | Ctrl+Alt+Space by XGrabKey | Clipboard + XTest Ctrl+V into the window focused at the shortcut, re-verified before the keystroke; Ctrl+Shift+V for terminals by WM_CLASS; previous clipboard text restored after 750 ms unless the user copied something else | Copy + notification |

Policy carried over from Windows: the target and text-output choice are fixed
when dictation starts; Record in the app's own window never pastes (the app
has focus) and offers Copy; failures leave the transcript on the clipboard and
in History; output never runs during shutdown. Closing cancels every request
and waits at most `DesktopHostShutdown.grace` (5 s); a request that ignores
cancellation cannot reach the window, and its record is recovered with its
audio at the next launch. On Wayland the focused app is
not visible to clients, so the paste goes to whatever is focused at delivery,
never to JustSpeakToIt's own window; focus re-verification and per-app
profiles are X11-only.

## iCloud sync

Linux joins the **Mac** CloudKit container through CloudKit Web Services
exactly as Windows does, and runs the same flow: `DesktopHostCloudSync` in
`SpeakDesktopHost`, with Linux adapters for the transport, keyring,
cryptography, loopback listener and browser. Formats, protocol evidence and
limits are in [Windows CloudKit sync](windows-cloudkit-sync.md); the one-time
CloudKit Console setup is in
[Windows development: iCloud sync](windows-development.md#icloud-sync). One
API token serves both apps: they share the callback URL.

- The **iCloud sync** group, below History, shows the status beside
  **Sign in…** and **Sign out**. Sign in asks CloudKit for Apple's sign-in
  page, opens it in the default browser (only `https` pages on `apple.com` or
  `icloud.com`; through the OpenURI portal inside Flatpak) and listens on
  `http://127.0.0.1:47823/cloudkit-sign-in` for the redirect carrying
  `ckWebAuthToken`, only during sign-in and for at most ten minutes. A
  connection that sends no complete request within five seconds is dropped,
  so an idle browser preconnection cannot hold the callback. The redirect is
  taken only from a process of this user (read from `/proc/net/tcp`) and only
  as a top-level browser navigation; see
  [Sign-in callback](windows-cloudkit-sync.md#sign-in-callback). The rotating
  token is kept in the keyring as `cloudkit.webAuthToken`.
- **Sync History with my Mac** and **Import API keys from my Mac** (off by
  default; needs the key-sync passphrase set on the Mac) take effect with
  **Apply**. Sync runs at launch, every five minutes, after each saved
  transcript and on **Sync now**. Transcripts from the Mac show "from your
  Mac" and refuse playback, opening audio and retry. Recordings made here
  upload with `originPlatform` `linux`, which the Mac shows as their origin.
  Only the key derived from the passphrase is stored (keyring,
  `cloudkit.apiKeySyncKey`); keys are imported from the canonical list only
  and never uploaded. A key typed here is never removed by a later deletion
  on the Mac.
- Sync state (cursor, bound iCloud user, acknowledgements, imported-key
  bookkeeping) is in `CloudSync/state.json` in the data folder, created
  private to the user. Signing out keeps it, History and saved keys; another
  Apple ID resets it and deletes nothing, as on Windows.
- Closing the window stops sync, lets running work end within three seconds
  and only then closes the controller.

The CloudKit API token is a build setting:
`scripts/windows-cloudkit/configure-cloudkit-web.py` writes the
`CLOUDKIT_WEB_API_TOKEN` secret into both `Sources/SpeakWindows` and
`Sources/SpeakLinux/CloudKitWebBuildConfiguration.swift`, which are committed
without one. No Linux workflow injects it yet, so every Linux build says
"iCloud sync is not available in this build" and otherwise works. For local
development set `JSTI_CLOUDKIT_WEB_API_TOKEN` (and
`JSTI_CLOUDKIT_WEB_ENVIRONMENT=development`) before starting the app.

## Parity matrix

"Verified" means exercised by an automated check listed here on Linux, not
proven on a physical desktop.

| Feature | State | Evidence |
|---|---|---|
| Shared host controller (record, stop, transcribe, cancel, close, output slot, History) | Verified | `SpeakDesktopHostTests` with a fake platform; Windows Swift type-checks against it (`scripts/typecheck-windows-swift.sh`) |
| All 31 batch models, OpenRouter discovery, post-processing | Shared code, verified by the portable tests | `swift test` (portable suite) |
| GTK window, events, record-bound History presentation | Verified headless on X11 and Wayland | `--ui-smoke-test` under Xvfb and headless Weston (`scripts/linux-wayland-smoke.sh`), window self-test, snapshot |
| Mac layout: sidebar pages, dashboard, History cards, totals, appearance | Verified headless on X11 | Window self-test (every page shown from the sidebar, the selected card holds its transcript, totals shown); `DesktopHistoryPresentationTests`; `--ui-screenshots` pictures of every page in light, dark and recording states (CI artifact). Real desktops and HiDPI **unverified** |
| Recording HUD | X11: verified headless (window type, no input focus, bottom-centre placement) and under Xvfb + Openbox, where a Zenity field kept focus while it showed; Wayland: result notifications only | Window self-test and screenshot tour; real GNOME/KDE X11 sessions, multiple monitors, fractional scaling and Wayland notifications **unverified** |
| Microphone capture (libpulse via PipeWire) | Verified with a virtual source | integration check: exact 100 ms frames, non-silent test tone; physical USB/Bluetooth microphones **unverified** |
| Microphone list and hotplug | Verified (monitors excluded; a new source triggers a refresh) | integration check; the saved choice keeps an "unavailable" row; physical hotplug **unverified** |
| Secret Service keys | Verified with GNOME Keyring | integration check; KWallet and the Flatpak Secret portal **unverified** |
| X11 paste, focus re-verification, clipboard restore | Verified under Xvfb + Openbox into a GTK (Zenity) field | integration check; real X11 desktops, terminals, Electron, LibreOffice **unverified** |
| X11 Ctrl+Alt+Space grab | Built; grab errors handled | **Unverified** by an automated key press |
| GlobalShortcuts portal | Protocol verified against a fake portal | GNOME 48 / KDE dialogs and real key presses **unverified** |
| Wayland paste (RemoteDesktop + Clipboard portals) | Protocol verified against a fake portal (sessions, persist mode, restore token reuse, SelectionWrite, keysyms) | **Unverified on a real compositor** (see risks below) |
| `--toggle` / app action | Built on GApplication | Forwarding **unverified** by an automated check |
| Import and conversion | Verified for WAV (44.1 kHz stereo to 16 kHz mono) | `LinuxAudioConversionTests` through GStreamer; MP3, M4A and Opus depend on installed plugins and are **unverified**; conversion runs only for 16 kHz-WAV-only models (Meta, Azure) |
| Live transcription transport (SwiftNIO, `SpeakLinuxWebSocket`) | Verified against the loopback probe | `SpeakLinuxWebSocketTests`: echo, PCM frames, ping/pong payload, peer close code and reason with acknowledgement, 2 × 2 MiB through a slow peer, fragmented Unicode and binary, cancellation of pending receive and pre-handshake send, abrupt disconnect, oversize, refused upgrade, and the shared Mistral client's four Voxtral scenarios. TLS (`wss`) to real providers, and live providers other than Mistral's protocol peer, **unverified**; HTTP(S) proxies are **not** honoured by this transport |
| Live transcription in the app | Wired to the same shared live clients as Windows (OpenAI, Deepgram, AssemblyAI, Speechmatics, Soniox, ElevenLabs, xAI dedicated speech-to-text, Mistral, Gladia, Cartesia, Rev.ai, Azure Voice Live, Reson8, Google Gemini, Meta Muse and Modulate); Grok Voice remains unexposed | Final-head native transport and real-provider acceptance remain **unverified**; source wiring and protocol fixtures do not establish provider receipts |
| Azure Speech resource endpoint | Settings shows an entry row while an Azure model is selected; entries are checked with the shared `DesktopHostAzureResource` rules before saving, and live Azure refuses to start without one | `DesktopHostAzureResourceTests`; the window self-test checks the row follows the picker |
| iCloud sync: History with the Mac, API-key import | Same shared flow as Windows (`DesktopHostCloudSync`); the flow, the adapters and the group verified against the fake CloudKit server | `DesktopHostCloudSyncTests` (sign-in, History both ways, deletion, sign-out, timeout, shutdown); `LinuxCloudKitTransportTests` and `LinuxLoopbackListenerTests` (fake server over a real loopback socket through URLSession and OpenSSL, callback, idle connections, cancellation); `LinuxEnvelopeCryptographyTests` (the CryptoKit/CNG vectors); window self-test; keyring integration check. A live CloudKit receipt, the Console setup (API token, callback URL, Production schema), a real Apple ID sign-in in a browser and the OpenURI portal inside Flatpak are **unverified** |
| Shortcut styles (press, hold, double-tap, both) | Session rules verified in the shared host | `SpeakDesktopHostTests`; the X11 grab reports press and release (integration check); portal Deactivated on real desktops **unverified** |
| History playback in the app | Verified player (a tone plays to the end through PipeWire) | App WAV recordings only; other imports use Open audio; audible hardware output **unverified** |
| App profiles | Controller support shared; **no Linux editor** | The X11 target's `/proc/<pid>/exe` path reaches the shared resolver, whose matcher is written for Windows paths: **unverified** |
| Read aloud | Verified with a stubbed Deepgram response, a device-free player and a virtual sink. Read aloud in History speaks the displayed transcript (the version shown) with a canonical Deepgram Aura or Flux voice chosen in the Read aloud group, in sentence-bounded segments within Deepgram's 2,000-character limit, through the History player: Play/Pause and Stop act on it, and recording, import, another row, History playback and close end it. The controller is shared with Windows (`DesktopHostReadAloud`). Synthesized WAVs are staged in `VoiceOutput/` (0700, files 0600) only while they play; leftovers from an earlier run are removed | `DesktopHostReadAloudTests` (segments, voice, missing key, Stop, supersession, persistence); `LinuxAudioPlaybackSpeechTests` (speech state, pause between segments, refused segments after Stop); `LinuxVoiceOutputTests` (private staging, a stubbed Deepgram WAV through the engine and speech mode); the window self-test (the button follows the presented record and reports its id, the picker reports the voice); the integration check (a 24 kHz segment plays to the end through PipeWire). A real Deepgram receipt (including Flux linear16/WAV), audible output on a physical desktop, speed control and other providers **unverified** |
| On-device transcription (whisper.cpp 1.9.4, the four pinned Whisper models) | Verified in a container with the CPU runtime built from the pin | `--local-transcription-self-test` downloaded the pinned tiny model through the app's installer and transcribed the JFK sample; `LinuxLocalTranscriptionTests` (GChecksum vectors; with the runtime: JFK, silence, cancellation before and during recognition, cache release by path, held removal); `DesktopHostLocalModelsTests` (download, pause and resume, readiness, removal ownership, a keyless local recording); `DesktopHostLocalModelVerificationTests` (a same-size tampered model the runtime refuses is deleted and yields no transcript; no separate rehash before loading); with the runtime, a same-size tampered copy and a digest the cached model's bytes lack are refused; `--self-test` (installer cycle, loader refusals); window self-test (Local models rows, events, no key row). Linux CI receipt for this revision, Vulkan (not built), aarch64 (not pinned), large models' speed and memory, and the group on real desktops **unverified**; no Flatpak runtime module |
| Status notifier (panel icon and menu, like the Mac's menu bar extra) | Verified against a fake `org.kde.StatusNotifierWatcher`: registration, icon pixmaps, tooltip, menu layout and a Quit click that closes the app | Integration check; how KDE Plasma, the GNOME AppIndicator extension (Ubuntu) and other panels draw it **unverified** |
| Launch at login | Outside Flatpak: an XDG autostart entry (`$XDG_CONFIG_HOME/autostart/com.justspeaktoit.JustSpeakToIt.desktop`, quoted `Exec` with `--background`) that the switch writes and removes, read back so a desktop's own startup settings (removal, `Hidden=true`, `X-GNOME-Autostart-enabled=false`) show here. Inside Flatpak: the Background portal's `RequestBackground` with `autostart` and the same command line, a refusal shown as off by the desktop, and the state last granted recorded in `settings.json`, because the sandbox cannot read the entry. A login launch creates the window minimised without asking for focus. Shared state, wording and status with Windows (`DesktopHostLoginItem`) | `LinuxLoginItemTests` (entry text and quoting, the desktop's switches, a dangling link); the window self-test (the switch follows the host and reports one click); the integration check (the fake portal grants, removes and refuses; `--background` starts minimised under Openbox). Real GNOME, KDE and XFCE sessions, the GNOME background-app dialog, and Wayland minimise-before-map **unverified** |
| IBus insertion | **Not implemented** | Later phases |
| Hands-free and silence | Shared sound-activation/utterance loop, bounded RAM pre-roll and manual silence auto-stop; fresh frozen X11 target, app profile and immutable provider inputs per utterance; record-bound output evidence; logind and an existing screen service required with fail-closed absence/service-loss handling | Not Apple's ML classifier. X11 paste keys are unconfirmed text delivery and stop listening; Wayland automatic utterances require clipboard-only output. X11 utterances resolve the canonical Linux executable matchers; Wayland exposes no app identity, so normal app settings apply and recording notes say so. Device/output method stay armed-run-owned; incompatible PCM-rate changes refuse before WAV/provider startup. Physical microphones/noise/latency, actual lock/sleep and installed Flatpak monitoring remain **unverified**; exact-head receipts and [settings coverage](desktop-settings-parity.md) qualify each slice separately |
| Flatpak | Built with `flatpak-builder` (GNOME 50, Swift 6.3.3); self-test and window smoke test pass in its environment | Installed `flatpak run`, portals from inside the sandbox and Flathub offline build **unverified** |

### Needs a physical desktop

1. **RemoteDesktop consent on GNOME**: whether a keyboard-only session is
   allowed without a screencast, what the dialog says, whether GNOME shows a
   screen-sharing indicator while the session is open, and whether the restore
   token avoids the dialog after a restart (and after a reboot on KDE, see KDE
   bug 480235). This decides whether the portal paste is acceptable; the copy
   fallback always works.
2. The Clipboard portal: GNOME and KDE must report `clipboard_enabled` and send
   `SelectionTransfer` when the target pastes.
3. GlobalShortcuts on GNOME 48: the first-run dialog, and that the binding is
   keyed by the app ID (needs the Flatpak or an installed `.desktop` file).
4. Insertion into Firefox, Chromium/Electron, LibreOffice, GNOME Terminal and
   Konsole (Ctrl+Shift+V), GTK and Qt fields, with a non-US layout.
5. USB and Bluetooth microphones through PipeWire.
6. iCloud sync, once the container owner has created the API token: that
   CloudKit Console accepts the plain `http://127.0.0.1` callback, a real
   Apple ID sign-in in Firefox and Chromium (and through the OpenURI portal
   from the Flatpak), a Mac transcript arriving and a Linux one reaching the
   Mac, and key import with a real passphrase.

## On-device transcription

The source now also provides explicit public Hugging Face GGML reference import,
separate verified Download, and native Local/Remote then Batch/Live filtering.
See [desktop Hugging Face imports](desktop-huggingface-import.md) for supported
formats, provenance, persistence and the **unexecuted** regression/native-control
evidence boundary. The earlier pinned-model receipts below do not qualify imports.

Linux transcribes recordings and imported files on this computer with the same
whisper.cpp 1.9.4 runtime and pinned GGML models as Windows
([windows-development.md](windows-development.md#on-device-transcription)).

- **Catalogue.** `LocalModelHostSupport.linux` runs whisper.cpp's GGML backend,
  so Linux projects exactly the shared catalogue entries Windows does (Whisper
  Tiny, Base, Small and Large v3 Turbo, under their canonical
  `local/whisperkit/...` identifiers). `LocalModelHostSupportTests` and
  `DesktopLocalTranscriptionTests` fail if the two hosts ever differ.
- **Shared workflow.** Downloads, verification, readiness, recognition and
  removal ownership moved from the Windows host into `SpeakDesktopHost`
  (`DesktopHostLocalModelManagement.swift`, `DesktopHostLocalModelRemoval.swift`)
  behind `DesktopHostLocalModelPlatform`; a host supplies only its SHA-256, its
  runtime loader and its presenter. Windows type-checks against it.
- **Download.** Models live in `$XDG_DATA_HOME/JustSpeakToIt/LocalModels`, one
  0700 folder per model. `LocalModelInstaller` downloads with HTTP Range into a
  `.partial` file, resumes after a pause or dropped connection, hashes the whole
  file with GLib's `GChecksum` SHA-256, then renames it atomically and writes a
  receipt. A tampered or truncated file is deleted and never used: when the
  runtime loads a model it hashes each byte as it hands it to whisper.cpp,
  through one open file, and frees the model unused unless the digest matches
  the pin, so a file replaced or rewritten at any moment cannot supply
  unverified bytes. The cached model is reused only for the same path and
  digest; the host then deletes a refused file and its receipt. The file is
  read on a thread of its own (`LinuxModelStream.c`), never while the runtime
  holds its lock, so a read that stalls (a hung network or FUSE mount, a FIFO)
  cannot keep a cancelled recording, or the next one, waiting; a device is
  refused without being read. Cancelling stops a load within 1 MiB and
  caches nothing. At most four readers live at once, so readers left blocked
  by a source that never resumes cannot pile up: a load is refused until
  their reads return.
- **Runtime.** `LinuxWhisper.c` opens `libggml-base.so.0`, `libggml.so.0` and
  `libwhisper.so.1` by absolute path, in dependency order, from the executable's
  directory or `JSTI_WHISPER_RUNTIME_DIRECTORY`, so their sonames resolve to
  those copies and neither `LD_LIBRARY_PATH` nor the system is searched (the
  libraries carry no RPATH or RUNPATH). The directory and libraries must not be
  links or writable by other users. It refuses any `whisper_version()` other
  than 1.9.4 (the headers vendored for Windows are shared, not copied), then
  registers the best-scoring `libggml-cpu-*.so` variant and, with the GPU choice
  on and `libggml-vulkan.so` present, Vulkan. It picks those files itself:
  ggml's own loader would also load whatever `GGML_BACKEND_PATH` names. At
  startup `GGML_NO_BACKTRACE` is set (unless already set), so a ggml abort or an
  escaped C++ exception never runs `gdb` from `PATH` against the app. Models
  stay loaded between recordings; cancelling aborts recognition.
- **Controls.** The model picker lists each model with its friendly name and
  state, for example "Whisper Tiny (on-device) — download in Local models", and
  hides the API key row for it. The Local models group lists each model with
  its size and state (Not downloaded, Downloading 42% of 74 MB, 10% downloaded,
  paused, Downloaded and verified, Removing…) and Download or Resume download,
  Cancel and Remove, with licence and provenance as the row's tooltip. The GPU
  switch appears only when the runtime has a Vulkan backend. Local recordings
  need no API key and skip the upload cap; silent recordings stay empty;
  History shows the friendly name. A model that a recording, import or
  transcription uses cannot be removed.
- **Checks.** `--self-test` checks the GChecksum vectors, a download, resume,
  tamper and removal cycle in private folders, and the loader's refusals
  (relative, missing, shared-writable, incomplete and damaged runtimes).
  `--local-transcription-self-test <wav> --expect <phrase> [--model <id>]`
  downloads the pinned model into `JSTI_LOCAL_MODEL_DIRECTORY` and transcribes
  the WAV (`JSTI_WHISPER_CPU_ONLY=1` keeps a Vulkan runtime on the CPU).

### Building the runtime

`scripts/linux-local-runtime/build-whisper-runtime.py` reads the whisper.cpp
pin (tag, commit, licence and JFK fixture digests) from
`scripts/windows-local-runtime/dependencies.json`, so both desktops build one
pin, and takes the Linux CMake switches from
`scripts/linux-local-runtime/dependencies.json`: shared libraries,
`GGML_BACKEND_DL` with every x86-64 CPU variant, OpenMP and native tuning off,
no RPATH. It refuses any library that is not an x86-64 shared object, carries
a search path or needs anything but the C and C++ runtimes and its own
libraries, and writes `runtime/`, `fixtures/jfk.wav` and `runtime-manifest.json`
(sizes, SHA-256, sonames, needed libraries, compiler).

```sh
sudo apt install cmake ninja-build g++ git python3
python3 scripts/linux-local-runtime/build-whisper-runtime.py \
  --output /tmp/whisper-runtime --work /tmp/whisper-work
export JSTI_WHISPER_RUNTIME_DIRECTORY=/tmp/whisper-runtime/runtime
.build/debug/SpeakLinux --local-transcription-self-test \
  /tmp/whisper-runtime/fixtures/jfk.wav --expect 'ask not what your country can do for you'
```

In a 4-vCPU container shared with other builds, the tiny model transcribed the
11-second sample in about 7.5 seconds on the CPU; that is a smoke check, not a
benchmark. `--vulkan` adds `libggml-vulkan.so` (it needs `libvulkan-dev` and
`glslc`, and uses the system's `libvulkan.so.1`); it has not been built or run.
Only x86-64 is pinned.

A Flatpak does not include the runtime yet. It would need a whisper.cpp module
built from the pinned commit (a pinned source, since Flathub builds offline)
with the same switches, installing the libraries beside
`/app/bin/justspeaktoit` and the licence under `/app/share/licenses`. Models
would download into
`~/.var/app/com.justspeaktoit.JustSpeakToIt/data/JustSpeakToIt/LocalModels`
over the existing network permission. None of this is built or tested.

## CI

The portable press-capture lease/PCM relay is currently fake-worker-qualified
ownership scaffolding only, not a Linux microphone-on-key-press implementation.
See the [shared ownership contract](windows-development.md) for admission,
bounded RAM, late cleanup and delivery-join guarantees. No native worker,
permission adapter, host handoff or settings row is installed. X11 press/release
events and Wayland portal Activated/Deactivated have different timing semantics;
portal activation is not physical-key-down or pre-recognition evidence. Native
start/stop remains unqualified for bounded readiness/cleanup, and neither a saved
preference nor a fake lifecycle result enables speculative capture.
Package failure events preserve the generating token and immutable admitted
identity across deferred delivery, with cleanup failure reported separately.
Use `DesktopPressCaptureLease.observingFailures(worker:onFailureEvent:)` for
correlated events; the original error-only initializer retains untyped,
ignored-argument trailing-closure compatibility without an initializer overload.
Optional `beginOwned` creates a package release ticket before queued opening
can run. Its retained token/attempt result joins real cleanup independently of
lease-global `settle()` and any later run. Cancelled waiters do not cancel IO;
failed cleanup retains exclusion, and repeated release observes that failure
until an explicit `retryRelease()` after it is observed. Owned runs reject
legacy `lease.retryClose(token)` with `invalidPhase` before any state reset or IO;
the exposed token is not legacy retry authority. Only the ticket's `retryRelease()`
retries owned cleanup. Legacy `begin` runs retain their existing `retryClose` behavior,
and workers without producer quiescence retain their relay fence before close. Retaining/releasing the
ticket on every startup/record/shutdown terminal path, Host failure mapping,
native ownership and WAV/context finalization remain separate prerequisites;
this package API neither installs them nor enables microphone capture.
The error-only observer remains a compatibility projection, not a second
subscription or a native/Host failure adapter.
Optional PCM deliveries preserve legacy Data batch projection while labeling
mono PCM16 sample offsets before/after reservation under the relay state lock.
The canonical `adoptDelivery` name keeps legacy `adopt` trailing closures
source-compatible even when their Data argument is ignored.
These are relay admission-order regions, not physical sample/gesture times or
an approved Host silence clock; physically earlier PCM submitted later is after
reservation. Legacy worker stop-time partial flush remains fenced and separately
unqualified, not made lossless by span metadata.
The additive `DesktopPressCaptureQuiescingWorker` contract requires an explicit
`quiesce(id:)` acknowledgement: after producer shutdown ALL final PCM/error
callbacks must have returned. An adopted, non-failed run continues admitting
those samples through its SAME bounded relay until acknowledgement, then fences,
settles admitted delivery and retires native resources before WAV finish/save.
Closing still excludes a new run throughout; there is no second PCM queue or
per-frame Task. Failed quiescence records the first capture cause, fences safely
and still attempts retirement; failed retirement retains the same owner for
explicit cleanup retry without replaying final PCM. A native failure arriving
after the fence remains latched and is published with its original token/identity
before release completion/Host disposition, without replacing an earlier relay cause.
Non-adopted and non-quiescing workers preserve fence-before-close. This is a
synthetic package/injected-Host stop contract, not native libpulse/driver evidence
or production activation; the production dependency stays unavailable. No native
adapter, permission grant, source identity, readiness or physical timing is inferred.

The injected package/internal Host startup transaction has no production factory
and does not activate production capture or successful dictation. It retains the real
owned ticket through early failure/ticket-delivery races, uses request-specific
failure/barrier acknowledgement and joins actual native cleanup before WAV finish.
Cleanup failure retains exclusion and permits only explicit owned retry, even
after close. A separate actor owns file operations; neither Host admission nor
settings queue waits on file/native IO. Finish is attempted once; independent
audio/History errors remain visible, and failed save retains the record/file
owner until explicit disposition retry. Closed persistence never presents UI.
See the [shared startup contract](windows-development.md) for bounds and limits.
An explicitly requested owned recording now uses that same owner's real Lease
reserve/readiness/adoption, with a separate Host descriptor rather than a fake
synchronous capture adapter. Its file-only PCM sink reuses the bounded relay
drain and canonical Context.receive. The memory model includes BOTH aligned
100 ms scratch and Context's temporary Data copy beyond the relay byte budget.
No per-frame Task/second PCM queue, provider or positive cue is installed.
Captured audio is annotated as non-dictation/retryable in real History; writer
failure, actual native cleanup, WAV finish and History save remain distinct.
This leaves synchronous normal/HF/comparison capture, canonical PCM ingestion,
silence clocks and fence-before-close unchanged. Native owner/callback lifetime,
permission/device/readiness, production recording handoff and final flush still
require separate qualification and activation.

`.github/workflows/linux.yml` (ubuntu-24.04, `swift:6.2.3-noble`, pinned by
digest) installs the packages above, then runs the boundary check, the
release build, `swift test` with `SPEAK_LINUX_TARGET=1`,
`scripts/linux-desktop-checks.sh` (uploading the window snapshot),
`scripts/linux-integration-checks.sh`, `--local-transcription-self-test` on
the JFK sample, and the Windows Swift type-check. The reusable
`linux-local-runtime.yml` first builds the pinned whisper.cpp runtime in the
same image (cached by its pins); the desktop job downloads it and a cached
tiny model, so the Linux platform tests run against the real runtime. Like
the Windows workflows it is advisory: it runs on pull requests and on `main`
but is not a required check, and nothing else waits for it.

## App ID

The app ID is `com.justspeaktoit.JustSpeakToIt`, under the same
`com.justspeaktoit` domain as the iOS bundle identifiers. It names the Flatpak,
the desktop file, the metainfo, the D-Bus name, the GlobalShortcuts binding and
the Flatpak data path. Treat it as fixed: changing it moves user data and
shortcut bindings.
