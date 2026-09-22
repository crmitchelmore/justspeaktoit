# Windows self-contained developer runtime bundle

The Mac-to-Windows cross pipeline previously produced only `SpeakWindows.exe`
and its resource directories, so running the app on Windows still needed the
Swift 6.2.3 toolchain and a Visual C++ redistributable installed by developer
tooling. This bundle closes that gap: a deterministic ZIP containing the
**production executable, its resources and only the redistributable runtime
DLLs it actually imports**, with licences, hashes and provenance. It is an
**unsigned developer bundle**. It is not an installer, an updater, a signed
release, an ARM64 build or evidence of physical audio, insertion or
performance acceptance; those remain separate gates.

## What the bundle contains

| Path | Origin | Why it is included |
|---|---|---|
| `SpeakWindows.exe` | `build-windows-app.py` release output; hash checked against `app-build-metadata.json` | Production app; a test-enabled build or anything importing `XCTest.dll`/`Testing.dll` is refused |
| `SpeakApp_SpeakCore.resources/` | SwiftPM resource bundle from the same build | Loaded beside the executable at runtime; `*Tests.resources` are skipped |
| 14 Swift runtime DLLs | Swift 6.2.3 runtime package `rtl.msi` from the pinned swift.org installer | Static import closure of the executable (see below) |
| `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll` | Microsoft's official `VC_redist.x64.exe` 14.51.36247.0, read as data | Static import closure; never taken from the Swift installer copy |
| `licenses/` | Swift, ICU, curl and zlib licences pinned to release-tag commits; the app's MIT licence; a Microsoft runtime notice | Redistribution terms and attribution |
| `THIRD-PARTY-NOTICES.txt`, `README.txt` | Generated deterministically | Human-readable summary and usage |
| `bundle-manifest.json` | Generated | Every file with size and SHA-256, the import graph, the sources and the policy used |

The Swift modules reached from the executable are `swiftCore`,
`swift_Concurrency`, `swift_StringProcessing`, `swift_RegexParser`, `swiftCRT`,
`swiftWinSDK`, `swiftDispatch`, `dispatch`, `BlocksRuntime`, `Foundation`,
`FoundationEssentials`, `FoundationInternationalization`, `FoundationNetworking`
and `_FoundationICU`. `FoundationXML`, `swiftSwiftOnoneSupport`,
`swiftRemoteMirror`, `plutil.exe` and the other runtime-package files are not
imported and are not shipped. Windows modules (`kernel32`, `user32`, `winhttp`,
`bcrypt`, the `api-ms-win-core-*` and Universal CRT `api-ms-win-crt-*` API sets
and so on) come from the operating system on Windows 10 and later and are never
copied.

Nothing from the compiler, SDK or test toolchain is packaged: no headers, import
libraries, Swift modules, symbol files, installers, cabinets, `XCTest`,
`Testing.dll`, test executables or test resources. `runtime-policy.json` lists
those forbidden patterns and the layout check refuses any match, as do the tests.

## How the dependency closure is computed

`scripts/windows-bundle/windows_pe.py` reads PE headers, the static import
directory, the delay-load import directory (both RVA-based and legacy
address-based descriptors) and the `VS_VERSIONINFO` resource without executing
anything. `build-windows-bundle.py` walks imports breadth-first from the
executable and classifies every module through the documented allowlist in
`scripts/windows-bundle/runtime-policy.json`:

- **Windows system modules** are an explicit list rooted in the imports actually
  observed on the production executable and its runtime, plus the two API-set
  patterns. They are recorded with their importers but never bundled. Presence on
  a CI runner is not a criterion.
- **Swift runtime modules** are the exact DLL names of the 6.2.3 runtime package.
- **Microsoft runtime modules** are the Visual C++ v14 runtime names published in
  the redistributable.
- **Test modules** cause a refusal, even when reached transitively.
- **Anything else** causes a refusal naming the importer and the module, so an
  unknown non-system DLL can never be silently omitted or silently shipped.

Every bundled DLL is read the same way, so a runtime DLL's own imports extend
the closure until only system modules remain. `additionalRuntimeModules` exists
for modules that only `LoadLibrary` would reveal; it is empty because the
Windows job's loaded-module evidence (below) fails if the process loads any
sampled non-system module from outside the bundle. In CI the closure is additionally
cross-checked against `llvm-readobj --coff-imports` from the pinned LLVM 20.1.8
tools, and a difference fails the build.

## Sources, provenance and licences

- **Swift runtime.** The swift.org installer is pinned by URL, SHA-256 and byte
  count in `scripts/windows-cross/dependencies.json`. Its bootstrapper manifest
  records `rtl.msi` (450,560 bytes) and `rtl.cab` (18,542,881 bytes) with SHA-512
  digests, which the cross bootstrap verifies before reconstructing the package
  from its MSI tables. The bundle records those digests, each DLL's MSI file key,
  and checks every DLL against the committed `swift-runtime-lock.json` SHA-256 and byte length. The lock is regenerated by `pin-swift-runtime.py` from the fully SHA-256-verified installer, its authenticated bootstrap manifest and SHA-512-verified MSI/CAB payloads. Mutable cache-local manifests are not trusted. Licence:
  Apache License 2.0 with Runtime Library Exception, pinned to
  `swiftlang/swift` at the `swift-6.2.3-RELEASE` commit.
- **ICU.** `_FoundationICU.dll` embeds ICU 74.1 (declared by
  `icuSources/include/_foundation_unicode/uvernum.h` in `swift-foundation-icu` at
  the release commit). The Unicode License v3 text with ICU third-party notices is
  pinned to `unicode-org/icu` at the `release-74-1` commit.
- **Embedded networking dependencies.** `FoundationNetworking.dll` statically links curl 8.9.1 and zlib 1.3.1, pinned by the Swift 6.2.3 Windows build configuration. Their release-commit COPYING/LICENSE texts are included separately; they are not attributed to the Swift licence.
- **Microsoft Visual C++ runtime.** `VC_redist.x64.exe` is pinned to the
  destination of Microsoft's documented permalink
  `https://aka.ms/vc14/vc_redist.x64.exe`, whose URL embeds the same SHA-256 as
  the downloaded bytes (`843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c`,
  18,731,856 bytes, version 14.51.36247.0, published May 2026). The build reads it
  as data only: it locates the two cabinets declared by the `.wixburn` section,
  inflates their MSZIP blocks in Python, checks each payload against the Burn
  manifest's hashes, decodes the `vc_runtimeMinimum_x64.msi` File and Media
  tables and takes the x64 DLL bytes by file key. Every extracted DLL must be an
  x64 DLL whose version resource equals the MSI's recorded version. No installer,
  bootstrapper application, MSI or custom action executes. Microsoft permits
  licensed Visual Studio users to distribute these runtime files unmodified with
  their programs ([Visual Studio 2022 redistribution list](https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution),
  [Community licence](https://visualstudio.microsoft.com/license-terms/vs2022-ga-community/));
  the runtime's own terms are linked from `https://aka.ms/VCRedistLicense`. The
  14.51 runtime is newer than the 14.44 toolset the app links against, as
  Microsoft's compatibility rule requires.
- **Application.** The repository's MIT licence is included.

`scripts/windows-bundle/dependencies.json` holds the pins and provenance notes.
Downloads are limited to `download.visualstudio.microsoft.com` and
`raw.githubusercontent.com`, capped at the pinned byte count and rejected on any
hash mismatch.

## Determinism

Entries are written in sorted order with a fixed 1980-01-01 timestamp, fixed
attributes, no extra fields and deflate level 9, so two builds from identical
inputs produce byte-identical archives; the evidence file records the zlib
version because deflate output depends on it. `bundle-manifest.json` inside the
archive hashes every other file, and `bundle-evidence.json` beside the archive
records the archive hash, the manifest hash and the source commit.

## Building and verifying locally

On macOS, after `build-windows-app.py` has produced the release output:

```sh
python3 -B -m unittest discover -s scripts/windows-bundle -p 'test_*.py'
python3 scripts/windows-bundle/build-windows-bundle.py \
  --app /path/to/windows-app-cross \
  --cache /path/to/private/windows-cross-sdk \
  --downloads /path/to/private/bundle-downloads \
  --output /path/to/windows-runtime-bundle
```

`--llvm-readobj /path/to/llvm-readobj` adds the import-table cross-check. Keep
the private cache, the downloads and the output on separate paths; the cache is
read only. On Windows:

```powershell
./scripts/windows-bundle/verify-windows-bundle.ps1 -BundleDirectory /path/to/windows-runtime-bundle `
  -Workspace $env:TEMP\bundle-run -ExpectedCommit <commit recorded in bundle-evidence.json>
```

## Continuous integration

`.github/workflows/windows-cross-proof.yml` gains one step and one job while the
earlier native and cross checks stay unchanged and strict:

1. The macOS `compile` job runs the bundle unit tests, assembles the bundle from
   the release output with the `llvm-readobj` cross-check and uploads
   `windows-runtime-bundle` (archive, manifest copy, evidence and build log).
2. A new `bundle-execute` job on `windows-2022` runs **without any Swift setup
   action**. Because the GitHub image may preinstall tools, omitting the setup
   action is not treated as isolation evidence. The script:
   - checks the archive hash, size and source commit, expands it, checks every
     extracted file's size and SHA-256 against the manifest, and refuses extra or
     forbidden files;
   - sets `PATH` to the Windows system directories only, clears Swift-related
     variables and `ICU_DATA`, confirms no `swift.exe` is reachable and that no bundled Swift
     runtime DLL exists in any `PATH` directory (copies of Microsoft runtime
     DLLs in `System32` are recorded, not trusted);
   - runs a **negative control**: `SpeakWindows.exe` with its resources but
     without the bundled DLLs, under `SEM_FAILCRITICALERRORS`, must exit with
     `STATUS_DLL_NOT_FOUND`. Exit code 0 means the runner supplied the runtime
     and fails the job;
   - extracts to a path with spaces and Unicode, then runs `--bundle-self-test`, `--self-test` and `--ui-smoke-test` from an unrelated empty working directory while
     polling the process's loaded modules, and fails if any module comes from
     outside the bundle or `%SystemRoot%`, if a bundled module was loaded from
     elsewhere, if a statically imported bundled module was not observed, or if
     the success markers or the window snapshot are missing;
   - asserts real SwiftPM release-note resources, Codable, Unicode regex, ICU locale/date formatting and atomic file I/O; a disposable copy missing `ReleaseNotes.json` must fail its explicit resource assertion. The short Foundation probe waits at most 10 seconds for the harness to acknowledge sampled DLL paths; this handshake only applies in its opt-in CLI test mode;
   - writes `bundle-execution-evidence.json`, the logs and the snapshot even when
     a check fails, then reports every failure.

The existing `execute` job keeps installing the pinned Swift runtime for the
separate test-enabled executable, as before.

## Evidence at this checkpoint

- The 41 unit tests pass locally with Python 3.14: PE import and version
  parsing on synthetic images, closure traversal with delay imports, cycles and
  case-insensitive names, refusal of unknown and test modules, path traversal,
  reserved names and case collisions, forbidden SDK/test files, MSZIP cabinet
  extraction with block history and checksums, compound-file and MSI table
  decoding, Burn container discovery, deterministic archives and end-to-end
  assembly, same-size runtime tampering, authenticated source-lock identity, truncated import directories and mapped-section boundaries.
- The Python delay-load reader was checked against Windows SDK binaries with
  real delay-load tables (for example `opcservices.dll` and `tracefmt.exe`
  across x86, x64 and arm64), and the redistributable reader decoded the real
  14.51.36247 bundle, its three MSI packages and their cabinets.
- Local build from the release cross output whose `SpeakWindows.exe` SHA-256 is
  `469e54e5eae191957ba55fc61cfc407897ea6d2df83736a24f8c3adda485e6a6` (the
  optimised build that passed [cross-runtime run 35735185760](https://github.com/crmitchelmore/justspeaktoit/actions/runs/35735185760)):
  `justspeaktoit-windows-x64-developer-local.zip`, 28 entries, 28,095,908 bytes,
  SHA-256 `da911eab7828dab81c83711a78fe9dcf3d4d0b836d01d8f636bd30618d3e7f67`,
  identical across two consecutive builds. Seventeen runtime DLLs were bundled
  from the two pinned sources; 49 distinct Windows modules were classified as
  system imports and left to the operating system.
- The Windows `bundle-execute` job has not run yet at this checkpoint. Its
  isolated-PATH run, negative control and loaded-module evidence are the runtime
  receipt for this bundle and must be green before the bundle is described as
  verified on Windows.

## Remaining gates

- Installer, uninstaller, upgrade and data-migration behaviour, and a
  clean-machine installation proof: the bundle runs from a folder and registers
  nothing.
- Code signing and SmartScreen reputation: the executable and archive are
  unsigned.
- ARM64 Windows: only x64 is built and verified.
- Physical microphone, provider, insertion and performance acceptance, as
  recorded in [Docs/windows-development.md](windows-development.md).
- Runtime updates: a newer Swift or Microsoft runtime requires re-pinning the
  lock files and re-running the whole pipeline.

## Independent review corrections

Fable authored the initial bundle implementation at `55bd5e06`. A separate Codex correction adds authenticated per-file Swift runtime pins, embedded curl/zlib notices, Windows path and PE bounds checks, relocated runtime tests and real resource assertions. Local Python tests and assembly of a 30-file bundle (17 runtime DLLs) passed with the pinned LLVM import cross-check. The corrected helper and harness subsequently passed their Windows execution gate at `91479ba8`, including loaded-module inspection and both negative controls. The initial empty-environment cleanup failure was reproduced and corrected before that receipt.

To regenerate the runtime lock after a deliberate Swift version change, use the verified installer and private pinned 7-Zip executable:

```sh
python3 -B scripts/windows-bundle/pin-swift-runtime.py \
  --installer /private/downloads/swift-6.2.3-RELEASE-windows10.exe \
  --seven /private/sevenzip/7zz --temporary-parent /private/cache \
  --output scripts/windows-bundle/swift-runtime-lock.json
```

The temporary extraction is confined to a newly created task directory and removed after the verified lock is produced. Normal bundle builds do not redownload or retain another installer.

Verified Windows checkpoint `91479ba8` (22 September 2026):

- [Native Windows run 35748290418](https://github.com/crmitchelmore/justspeaktoit/actions/runs/35748290418)
  passed **578 tests, 13 optional skips, zero failures**, then all five WinHTTP
  loopback probes and native executable/window checks.
- [Mac cross-build and Windows execution run 35748289497](https://github.com/crmitchelmore/justspeaktoit/actions/runs/35748289497)
  passed **578 tests, 13 optional skips, zero failures** from the exact Mac-built
  release test executable. The production executable also passed playback,
  native/window and isolated runtime-bundle checks. Both runs tested PR merge
  `e1821430ef92d8997e84de3365fd6e46b2eae968`; its source tree is identical to
  `91479ba8`.
- The [runtime bundle artifact](https://github.com/crmitchelmore/justspeaktoit/actions/runs/35748289497/artifacts/10704123666)
  contains a 30-file developer ZIP with 17 runtime DLLs. In all three isolated
  runs, the application and all 17 DLLs loaded from the extracted bundle with
  no foreign modules or missing static imports. Swift was absent from PATH,
  the working directory was empty, and the bundle path contained spaces and
  Greek characters. Removing the DLLs produced `STATUS_DLL_NOT_FOUND`; removing
  the real application resource produced exit 1.
- ZIP SHA-256: `2d45734186d24cb861b5ff6c993c9dec369cb5288187ad860891085863d36c39`.
  The unsigned production executable SHA-256 is
  `488e76225a60e59b9f84d1ba607abc1e735d2269f14a285d5dcd74c8db57e6e9`.
  The three native/cross/bundle window screenshots were byte-identical and
  inspected for control bounds. These tests use synthetic content. The hosted
  runner had no physical output endpoint, so three audible playback cases were
  explicitly skipped; microphone, speaker/Bluetooth/USB and external-app
  insertion acceptance remain open.
