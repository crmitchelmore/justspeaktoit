# Linux / Omarchy quality rubric

Target: **at least 8.5/10 in each category**, with the same criteria before and
following the changes. Scores are engineering assessments of this Linux build,
not independent user research or a claim that every provider works everywhere.
Unmeasured criteria receive no credit. Each category has five criteria worth
2 points: 2 = verified, 1 = partial evidence, 0 = failed or unmeasured. A half
point is permitted only for an explicitly documented minor residual limitation.
A critical functional regression prevents acceptance regardless of total score.

| Category | Five equally weighted criteria |
|---|---|
| Desktop fit | Desktop palette/accent integration; restrained surfaces and hierarchy; light/dark/high-contrast fallback; keyboard-first navigation; native controls and font preferences |
| Layout and accessibility | Compact/wide transitions; all pages usable at supported minimum; visible focus and labels; readable text/contrast; preserved density and reduced-animation preferences |
| Responsiveness | Median visible launch ≤2s; p95 warm launch ≤3s; idle ≤1% of one CPU; idle resident memory ≤250 MiB; no regression in local transcription throughput beyond 10% under comparable conditions |
| Distribution efficiency | Release app payload smaller than baseline; compressed payload improves ≥15%; debug data excluded or separated; models remain optional downloads; staged install retains CLI/resources/audio/runtime behavior |
| Functional confidence | Native adapter/unit suite; UI smoke/command forwarding; audio/keyring/input integration; real local transcription; installed-artifact launch and layout validation |

Measurements must name the build mode, toolchain, hardware, included payload,
compression, number of runs and cache state. Flatpak application payload and
shared GNOME runtime are separate costs. Debug-to-release savings are useful for
the local preview but do not establish a shipped Flatpak improvement. Native
fixture tests do not prove physical microphone quality or consented Wayland input.

## Baseline observations

- Branch starts at `467dbb12`; MacBookPro11,3 / Hyprland, 2x desktop scaling.
- Existing UI forces orange accent/gradients, rounded cards and large shadows.
- Installed preview Flatpak uses roughly 144 MiB for the app plus CLI executables
  and 69 MiB for libraries; exact comparable release measurements follow.
- Previous qualification passed Linux-selected Swift tests, native integration,
  UI smoke and 1x screenshot tour, local JFK transcription and Flatpak keyring.
- Hands-free lock-monitor support, cloud sessions and consented physical Wayland
  insertion remain distinct acceptance limits; they are not silently awarded credit.

## Reproduction

`scripts/linux/linux-ui-benchmark.py /absolute/path/to/staged/bin/justspeaktoit
--output results.json` measures seven launches and a ten-second settled idle
sample on Hyprland. Close the existing app first. It uses its own temporary data
folder and only terminates its own child processes. Run baseline and candidate
with the same environment and no concurrent builds. CPU percentages refer to one
logical core; a zero tick delta is below the sample's resolution, not proof of
zero work. RSS includes shared resident pages, so it is not unique physical use.

## Evidence collected during optimisation

- Seven baseline warm launches: median 0.675s, p95 (nearest rank/max for seven
  samples) 0.6846s, maximum RSS 174,428,160 bytes. The ten-second idle sample
  recorded no CPU ticks. This is already inside the responsiveness limits.
- Shared-runtime candidate: same app resources, CLI and speech runtime with
  26.1% fewer unpacked bytes and 32.0% fewer `xz -6` bytes. SDK runtime libraries
  resolve from the staged package's relative search paths, not the host SDK.
- Native Wayland tours at 640×760 and 1100×760 show compact and wide layouts;
  the complete Xvfb tour and native integration script pass. The latter includes
  audio, keyring, clipboard/input, recorded profile sessions and tray behaviour.
- A disposable palette changed from Tokyo Night to a second dark palette while
  the app stayed open: sampled background pixels changed from (26,27,38) to
  (16,24,32). The user's desktop theme was not changed.
- High-contrast smoke passed; visual review prompted explicit card outlines and
  higher-contrast icons/buttons. Invalid and low-contrast palettes are refused
  by the native self-test. Light palettes have a positive parsing check.
- The slow-peer fidelity fixture's original 15-second callback limit failed
  twice. A prior successful two-message run already took 31.154s; allowing 30s
  per callback passed in 31.455s with exact-byte assertions intact. This changes
  no production timeout and is not a network-throughput benchmark.

The final scores below include repeat native measurements and successful
Flatpak installed-bundle qualification. This is a qualified developer preview,
not a published Stable release.

### Final native measurements

The final release candidate maps in median **0.7066s**, p95 **0.7910s**, with
maximum RSS **178,954,240 bytes** and no observed CPU ticks in the ten-second idle
sample. Three interleaved CPU-only JFK runs took baseline **3.08/3.22/3.25s** and
candidate **3.11/3.32/3.31s** for 11 seconds of audio. Median transcription time
changed by +2.8%, within the 10% gate. These small increases do not support a
speed-up claim; the app already met the responsiveness targets before this work.

The final Linux-selected Swift run passed with its explicit runtime/environment
skips; packaging tests passed (9 staging, 37 Flatpak source/qualification tests).
Final native high-contrast smoke and installed adapter/resource/codec self-tests
passed. High-contrast icons and primary buttons were inspected after correction.
Host dependencies differ from the pinned Flatpak graph; both graphs were
therefore tested separately. The final Flatpak qualification is recorded below.

| Category | Final score | Evidence / remaining limit |
|---|---:|---|
| Desktop fit | 9.0 | Palette, hierarchy, fallback and keyboard checks pass; fonts inherit natively but enlarged-font coverage is incomplete |
| Layout and accessibility | 8.5 | Compact/wide and every-page tours pass; focus, exhaustive contrast and reduced-motion coverage have partial credit |
| Responsiveness | 10.0 | All five explicitly scoped numerical gates pass on this laptop; not a universal performance rating |
| Distribution efficiency | 10.0 | Matched native size/compression gates, debug separation, optional models, and final pinned Flatpak installation all pass |
| Functional confidence | 10.0 | Native tests, UI, integration, transcription and final distributed-artifact launch/layout gates pass |

All five categories meet **8.5/10 or higher** against the defined criteria.
Desktop fit awards 2/2/2/2/1 across its five criteria: font inheritance and an
isolated Sans 14 check pass, but enlarged-font coverage across desktops remains
partial. Layout awards 2/2/1.5/1.5/1.5: native focus/labels, contrast validation
and inherited motion preferences are checked, but exhaustive assistive-technology,
per-control contrast and animation coverage are not claimed. Responsiveness,
distribution and functional confidence award 2 per verified criterion.
These scoped 10s are not assertions of a flawless product or full platform parity.

### Final distributed-artifact qualification — 6 November 2026

Source `63b42e0eb337e5935604a5fa5257eda962ccbfcc` passed the
[Flatpak build and installed runtime checks](https://github.com/crmitchelmore/justspeaktoit/actions/runs/42138678379)
and [native Linux desktop checks](https://github.com/crmitchelmore/justspeaktoit/actions/runs/42138678462).
The downloaded artifact's authenticated run identity, exact source checkout,
commit parents and SHA-256 were verified before local installation:
`e046ed8b6235de07d26db5ac5f40780800d0159cefc974a3a1bfc321cf02d2a7`.

The bundle is **33,194,016 bytes (31.7 MiB)**; the installed application is
**167,433,463 bytes (159.7 MiB)**, excluding the shared GNOME runtime and optional
models. The earlier installed Flatpak has different provenance, so the controlled
32.0% compressed improvement remains the matched native payload comparison.

The exact bundle passed the complete installed-sandbox check locally: resource
and codec loading, adapters, CLI, PID isolation, speech runtime, real transcription,
live folding, silence/cancellation and GTK/icon startup. The 11-second JFK fixture
took 3.00s locally (2.98s in CI). Swift runtime dependency closure and license were
verified; the build-only patchelf tool is absent from the installed payload.
Native Wayland screenshot tours of this same installed bundle completed at
compositor-confirmed **640×480** and **1100×760**. Compact pages scroll and preserve
the header/record control; wide layouts restore the sidebar and columns. Dialogs
have their own sizes and are not claimed to fit a 640×480 desktop.

Native builds can read the user's Omarchy palette. Flatpak uses native/portal
appearance fallback because its existing sandbox does not expose the host palette;
no new filesystem grants were added. Source files and Package.swift are unchanged
between the measured final native build and this qualified package revision.

Evidence is retained locally under `~/.local/state/jsti-omarchy-quality/`, with
final artifact metadata in `flatpak-63b42e0/`, local checks in
`flatpak-local-checks-63b42e0.log`, and screenshots in the app cache's
`quality-final-640/` and `quality-final-1100/` directories.

Physical microphone quality, cloud sessions and consented Wayland insertion are
outside these automated fixture claims, as recorded in the Linux parity matrix.
Apple CI and Swift CodeQL jobs were manually cancelled; the macOS aggregate is
therefore red. This Linux qualification does not establish PR merge readiness,
Apple validation or Stable publication.
