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
| iOS | Unmeasured | Unmeasured | Obtain App Store Connect thinned installed/download sizes before claiming a reduction |

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

### Remaining gates

- iOS: App Store Connect thinned download and install sizes for a pre and post
  build, which cannot be read from GitHub release assets.
- Flatpak: installed size from `flatpak install` of both bundles on Linux.
- Mac universal: an owner decision on whether the legacy download should keep
  embedding the CLI. This is the single largest optional component.
- Startup: end-to-end launch and first-recording latency on real devices for
  each platform. The deferred model discovery and History changes have
  unit-level coverage only.

## Responsiveness

Remote live transcription now defers local-model discovery until a local
streaming mode actually needs it. Eight focused resolver tests cover the
selection and availability behavior. This removes unnecessary discovery work;
an end-to-end latency improvement has not yet been measured.

Test-support migration fixtures are excluded at final Windows/Linux production
staging, while producer artifacts keep the fixtures needed by tests. No runtime
dependency, language, codec, model, offline capability or update support is
removed by this filter.

Protected CI, native packaging, signing/notarization, Apple processing, tester
readiness and Alpha shipment are separate acceptance gates. A source merge or
these experimental savings alone do not establish delivery.
