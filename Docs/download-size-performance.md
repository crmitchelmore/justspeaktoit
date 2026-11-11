# Download size and responsiveness

Work is tracked in [#1295](https://github.com/crmitchelmore/justspeaktoit/issues/1295).
Measurements below describe cached artifacts and controlled experiments, not
newly published release sizes.

## Baselines and experiments (28 October 2026)

| Surface | Before | After | Qualification |
| --- | ---: | ---: | --- |
| Alpha 42 arm64 Mac DMG | 19,518,794 bytes | Unmeasured | Published asset baseline; primary app already excludes the CLI |
| Alpha 42 universal Mac DMG | 47,757,015 bytes | Unmeasured | Published asset baseline |
| Cached arm64 Mac CLI ZIP | 5,155,721 bytes | 4,518,546 bytes | Same ZIP writer and ad-hoc signing on both copies; 637,175 bytes (12.36%) saved |
| Cached x64 Windows ZIP | 73,627,592 bytes | 53,770,367 bytes | Same ZIP writer; debug-only transform; 19,857,225 bytes (26.97%) saved |
| Cached ARM64 Windows ZIP | 53,313,925 bytes | 33,477,632 bytes | Same ZIP writer; debug-only transform; 19,836,293 bytes (37.21%) saved |
| Flatpak | Unmeasured | Unmeasured | Removes unconsumed Parakeet and redundant version filenames after dependency checks |
| iOS | Unmeasured | Unmeasured | Needs App Store Connect thinned sizes; see [iOS thinned sizes](#ios-thinned-sizes) |

The Mac experiment used an Alpha 42 CLI copy; its normalized ZIP baseline is
different from the published 5,272,903-byte asset. Runtime sections, UUID,
nondebug symbols and passive help/version output matched. A complete matching
dSYM must be produced from fresh build objects before stripping and signing.
The primary arm64 app is already stripped; this experiment does not establish a
smaller primary DMG.

Windows experiments used dated build-550 artifacts (source `1d315c66`), preserving
declared runtime section contents, imports and loader metadata. The experiment
ZIPs retain old bundle metadata and are not installable release candidates.
Native ARM64 optimization depends on the installed Swift toolchain supplying
`llvm-objcopy.exe`; absence keeps the original executable and records that it
was not optimized. Unstripped originals remain diagnostic artifacts outside
the final runtime bundle. Native launch, transcription, CLI, MSIX lifecycle and
update validation remain required.

Flatpak's OSTree deduplicates identical contents: removing duplicate paths is
not itself evidence of download-byte savings. Runtime closure checks retain
all supported CPU and Vulkan backends, canonical regular SONAME files and
licenses. Installed Flatpak transcription and sandbox checks remain required.

## Published Alpha before and after (3 November 2026)

These are the published assets themselves, measured from GitHub release
downloads. Alpha 42 (`abe80125`) predates #1298 and #1304; Alpha 44
(`47795dfb`) contains both. Alpha 43 (`190620cf`) matches Alpha 44 within a
few kilobytes on every surface. "Unpacked" is the sum of ZIP entry sizes, or the
`.app` bundle's byte total extracted from the DMG. Every value is in bytes.

| Asset | Alpha 42 download | Alpha 44 download | Alpha 42 unpacked | Alpha 44 unpacked |
| --- | ---: | ---: | ---: | ---: |
| Mac arm64 DMG (app) | 19,518,794 | 19,518,122 | 37,849,067 | 37,849,060 |
| Mac universal DMG (app) | 47,757,015 | 46,477,356 | 111,692,927 | 104,949,592 |
| Mac CLI arm64 ZIP | 5,272,903 | 4,616,089 | 19,251,904 | 15,883,680 |
| Mac CLI x86_64 ZIP | 5,491,838 | 4,866,218 | 19,638,240 | 16,269,232 |
| Windows x64 ZIP | 73,703,492 | 53,776,210 | 246,440,999 | 158,201,755 |
| Windows ARM64 ZIP | 53,391,437 | 33,493,515 | 185,076,235 | 93,175,819 |
| Linux x86_64 Flatpak bundle | 47,517,120 | 46,022,776 | Not measured | Not measured |

Published savings: Windows x64 19,927,282 bytes (27.04%) download and
88,239,244 bytes (35.81%) unpacked; Windows ARM64 19,897,922 bytes (37.27%)
download and 91,900,416 bytes (49.66%) unpacked; Mac CLI ZIPs 656,814 bytes
(12.46%, arm64) and 625,620 bytes (11.39%, x86_64); Mac universal DMG 1,279,659
bytes (2.68%), entirely from the embedded `speak` CLI (38,912,704 to 32,169,376
bytes). The arm64 DMG is unchanged, as predicted. The Flatpak bundle shrank
1,494,344 bytes (3.14%), but that bundle is an OSTree static delta that could
not be unpacked here, and #1324 and other source changes also landed between
the two builds, so this is not attributed to packaging alone. The Windows ZIP
also no longer carries the 14 `SpeakApp_SpeakTestSupport.resources` migration
fixtures.

### Largest remaining components (Alpha 44)

| Surface | Component | Bytes | Needed? |
| --- | --- | ---: | --- |
| Mac universal | `JustSpeakToItAlpha` executable (two slices) | 68,419,248 | Yes: the app |
| Mac universal | Embedded `Contents/MacOS/speak` CLI | 32,169,376 | Deliberate for the legacy download (#775, `verify-architecture.sh embedded-cli`); the same CLI is also published as standalone ZIPs. Removing it is a product decision, not a packaging fix |
| Mac arm64 | `JustSpeakToItAlpha` executable | 33,521,328 | Yes; already stripped, no embedded CLI |
| Mac both | `Sparkle.framework` | 2,747,433 | Yes: updates |
| Mac both | `FluidAudio_FluidAudio.bundle` | 1,020,515 | Yes: local Parakeet/Nemotron support |
| Windows x64 | `ggml-vulkan.dll` | 55,582,720 | Yes: Vulkan GPU local transcription; x64 only |
| Windows both | `_FoundationICU.dll` | 35,723,776 (ARM64), 35,854,336 (x64) | Yes: required by Swift Foundation on Windows |
| Windows x64 | Nine `ggml-cpu-*.dll` variants | about 7.6 MB together | Yes: runtime CPU feature dispatch; each is under 1 MB |
| Windows both | `SpeakWindows.exe` / `speak.exe` | 24,391,168 / 10,672,128 (x64) | Yes; debug sections now stripped |

Local transcription and post-processing models are not in any package. They
are downloaded on demand from the catalogue in
`Sources/SpeakCore/ModelCatalog+LocalModels.swift` (from about 44 MB to
1,100 MB each), so they do not count towards these package sizes.

### Alpha 45 (3 November 2026)

Alpha 45 (`9146079e`) is the latest published build. Download sizes in bytes,
read from the release assets:

| Asset | Alpha 45 |
| --- | ---: |
| Mac arm64 DMG | 19,570,664 |
| Mac universal DMG | 46,662,620 |
| Mac CLI arm64 ZIP | 4,667,594 |
| Mac CLI x86_64 ZIP | 4,923,856 |
| Windows x64 ZIP | 53,867,448 |
| Windows ARM64 ZIP | 33,576,619 |
| Linux x86_64 Flatpak bundle | 46,848,088 |

Every Mac release records each DMG's download, installed app, main executable
and embedded CLI sizes in the `release-mac.yml` job summary. The Flatpak
installed check (`scripts/linux/linux-flatpak-checks.sh`) now logs the bundle size
and the installed app deployment size, excluding the shared GNOME runtime, in
`flatpak-installed-checks.log` in the `justspeaktoit-flatpak-x86_64` artifact.
The first CI measurement (PR #1339, Linux Flatpak run 41813047402, from Alpha 45
source plus this change) was a 46,465,824-byte bundle and a 223,107,509-byte
installed app deployment.

### Mac CLI symbols

Both CLI builds (`build-speak-cli-standalone.sh` for the standalone ZIPs and
`build-speak-cli.sh` for the CLI embedded in the universal app) call
`prepare-mac-cli-symbols.sh` before signing. It generates and verifies a dSYM
from the fresh build objects, checks its UUIDs match the executable, then runs
`strip -S` and checks the UUIDs again. `release-mac.yml` passes the CLI dSYMs
to the Sentry upload job with the app dSYMs, so stripping does not lose crash
symbolication. The Alpha 44 table above shows the published saving.

### iOS thinned sizes

GitHub release assets cannot show iOS sizes: the App Store thins each build per
device. Read them from App Store Connect for the build before and after a
change, under the same device:

1. In App Store Connect, open the app, then **TestFlight** and select the build
   once its processing finishes.
2. Open **Build Metadata** and choose **App File Sizes**. The table lists the
   compressed download size and the uncompressed install size for each device
   variant.
3. Record both sizes for one current device, such as the newest iPhone, plus
   the universal row, with the build number and source commit.

To check before upload, export the archive for Ad Hoc distribution with **App
Thinning: All compatible device variants**. Xcode then writes an
`App Thinning Size Report.txt`. Use App Store Connect for published numbers.

### Remaining gates

- iOS: App Store Connect thinned download and install sizes for a pre and post
  build, using the steps above.
- Flatpak: no earlier installed-size baseline exists. CI records each new
  bundle's sizes from now on, starting with the figures above.
- Mac universal: an owner decision on whether the legacy download should keep
  embedding the CLI. This is the single largest optional component.
- Startup: end-to-end launch (process start to first usable window and menu
  bar item) and first-recording latency on the Mac, and on real Windows, Linux
  and iOS devices. On the Mac, only `WireUp.bootstrap` has been measured. The deferred model discovery and History changes
  have unit-level coverage only.

## Responsiveness

Remote live transcription now defers local-model discovery until a local
streaming mode actually needs it. Eight focused resolver tests cover the
selection and availability behavior. This removes unnecessary discovery work;
an end-to-end latency improvement has not yet been measured.

### Mac launch path (4 November 2026)

`WireUp.bootstrap` runs on the main thread before the first window replaces
its loading view. Temporary timers around each step measured release builds
on an M-series Mac mini, launching the binary directly with this user's
settings and permissions already granted. The machine was also running other
builds, so treat single runs as noisy and compare medians.

| Step | Main-thread time |
| --- | ---: |
| `AppSettings.init` | 84-117 ms, of which `SMAppService.mainApp.status` is 80-115 ms |
| `PermissionsManager.init` (four status checks) | 60-70 ms |
| `AudioInputDeviceManager.init` (first Core Audio query) | 56-80 ms |
| `MainManager.init` | 17-32 ms |
| `HUDWindowPresenter.init` | 19-29 ms |
| Everything else, including `configureServices` | under 15 ms in total |

`AppSettings.init` reconciled the login item on every launch, even with
**Launch at login** off, through a synchronous XPC round trip. It now runs on a
serial utility queue. The queue keeps the order of the settings, so the latest
toggle still wins, and failures are still logged. Injected test dependencies
stay synchronous.

Over 8 alternating launches of each release binary:

| Measurement | Before (median) | After (median) |
| --- | ---: | ---: |
| `AppSettings.init` | 89 ms | 2.4 ms |
| Whole `WireUp.bootstrap` | 310 ms (270-577) | 210 ms (203-230) |

The other steps stay eager on purpose:

- Permission statuses feed onboarding, the hot key and the menu immediately.
  Deferring them would delay or misreport permissions.
- The first Core Audio query loads the audio HAL. Recording and the
  preferred-microphone switch need it, so deferring it moves the stall into the
  first recording.
- The HUD panel is built at launch so its first appearance at recording start
  does not pay for window and hosting-view creation.

### Start-to-capture path (#611)

Real-Mac History data puts recognised hotkey to capture live at p50 109 ms and
p95 193 ms; the target is under 100 ms. A temporary per-step timer in a
release build, driven through the automation socket with a staged recorder,
measured the steps between `startSession` and capture live:

| Step | Time |
| --- | ---: |
| Profile, guards and API-key check | under 1 ms |
| `TextOutputTarget.capture()` (focused element) | 0.5-38 ms |
| HUD "Getting ready", including a microphone TCC query | about 14 ms |
| `startRecording` microphone TCC query | about 13 ms |
| `AVAudioRecorder.record()` on a staged recorder | 47-73 ms |

A command-line benchmark found each `AVCaptureDevice.authorizationStatus(for:)`
call costs 15-35 ms, with no caching between calls.
`AVAudioApplication.recordPermission` costs 13-20 ms, so switching APIs does not
help. The start path queried the status twice in a row. The HUD now uses the
cached status, and `startRecording` keeps the single authoritative check
before the microphone opens. That removes one query, about 13-20 ms, from every
start. The HUD's health is still refreshed as soon as capture is live, and a
missing permission still fails the start with its own error.

`record()` dominates what remains. Removing it would mean writing the
recording from the live engine's tap instead of a second `AVAudioRecorder`, a
larger change outside this step. Real hotkey timings after the change need a
new History sample on the owner's Mac. Automated UI or hotkey runs must not
take over that Mac, so these figures come from ordinary use.

Test-support migration fixtures are excluded at final Windows/Linux production
staging, while producer artifacts keep the fixtures needed by tests. No runtime
dependency, language, codec, model, offline capability or update support is
removed by this filter.

Protected CI, native packaging, signing/notarization, Apple processing, tester
readiness and Alpha shipment are separate acceptance gates. A source merge or
these experimental savings alone do not establish delivery.
