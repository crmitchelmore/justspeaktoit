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
