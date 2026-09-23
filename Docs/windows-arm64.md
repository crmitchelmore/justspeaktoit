# Windows ARM64 developer build

Windows ARM64 has its own CI workflow,
[`windows-arm64.yml`](../.github/workflows/windows-arm64.yml). It mirrors the
proven x64 checks natively on a GitHub `windows-11-arm` runner: build, the full
test suite, the WinHTTP loopback probes, the executable self-test, the native
window smoke test and on-device transcription. It then builds a self-contained
bundle and a developer MSIX from the same executable and exercises them. Every
ARM64 program it runs must be a native ARM64 image running as an ARM64
process, not an x64 build running under Windows' x64 emulation.

**Status.** This is CI wiring and tooling, not a receipt. No run of
`windows-arm64.yml` had completed when it was written, so there is no ARM64
test count, executable hash or bundle hash yet. ARM64 is not verified until a
run for the exact revision passes. The ARM64 Swift runtime the bundle uses is
now pinned and was authenticated locally from the official installer (see
[ARM64 Swift runtime pin](#arm64-swift-runtime-pin)); that is a check of
pinned inputs on a Mac, not ARM64 execution. It is still a developer build,
not a signed release or an updater. It does not claim feature parity,
physical-device acceptance or measured performance; see
[Remaining gates](#remaining-gates). [Windows development](windows-development.md)
is the parity matrix.

## Primary sources (checked 23 September 2026)

| Fact | Source |
|---|---|
| Swift 6.2.3 ships a Windows ARM64 installer, `swift-6.2.3-RELEASE-windows10-arm64.exe` | [swift.org Windows install page](https://www.swift.org/install/windows/) |
| That installer's SHA-256 is `42e1dbfdae613a67d99b62e84aa6503620760d35391f409f5ac64862fe70f747`. The same manifest's x64 value equals this repository's independently computed x64 pin | [winget `Swift.Toolchain` 6.2.3 manifest](https://github.com/microsoft/winget-pkgs/blob/master/manifests/s/Swift/Toolchain/6.2.3/Swift.Toolchain.installer.yaml) |
| The pinned x64 installer carries the ARM64 SDK (`sdk.windows.arm64.cab`: `aarch64` modules and import libraries, ARM64 `XCTest.dll`/`Testing.dll` in `bin64a`) but no ARM64 runtime DLLs | Local extraction of the pinned installer |
| `windows-11-arm` is a standard runner for public repositories: 4 CPUs, 16 GB RAM, 14 GB SSD, arm64 | [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) |
| The Windows 11 Arm64 image is generally available. GitHub has taken it over from Arm's partner repository | [runner-images](https://github.com/actions/runner-images), [partner-runner-images](https://github.com/actions/partner-runner-images) |
| Image 20260914.169.1: Windows 11 build 26200, Visual Studio 2022 Enterprise 17.14 with the ARM64 tools, Clang toolset and Windows SDK 26100, LLVM 22.1.8, Ninja 1.13.2, CMake 4.4.3, Python 3.13.15, PowerShell 7.6.6. Microsoft Defender stays enabled | [Windows11-Arm64-Readme](https://github.com/actions/runner-images/blob/main/images/windows/Windows11-Arm64-Readme.md) |
| The pinned `compnerd/gha-setup-swift@bbae8ce` accepts `build_arch: arm64` and then installs the `windows10-arm64` installer. It does not verify the download, as for x64 | [action.yml at that commit](https://github.com/compnerd/gha-setup-swift/blob/bbae8ce86bac5a3449f3992b3d88bc4ca25f2057/action.yml) |
| "The X64 Redistributable package contains both ARM64 and X64 binaries" | [Latest supported Visual C++ Redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) |
| ggml at the pinned whisper.cpp 1.9.4 stops with "MSVC is not supported for ARM, use clang", and `GGML_CPU_ALL_VARIANTS` with "Unsupported ARM target OS" on Windows | [`ggml/src/ggml-cpu/CMakeLists.txt`](https://github.com/ggml-org/whisper.cpp/blob/927cfce34f31707e17f2bff35c349632fb9e2c3a/ggml/src/ggml-cpu/CMakeLists.txt), [`ggml/src/CMakeLists.txt`](https://github.com/ggml-org/whisper.cpp/blob/927cfce34f31707e17f2bff35c349632fb9e2c3a/ggml/src/CMakeLists.txt) |
| Upstream whisper.cpp publishes Windows ARM64 CPU, OpenCL (Adreno) and CUDA builds, with clang and `cmake/arm64-windows-llvm.cmake` (`-march=armv8.7-a`), and no Vulkan build | [`release.yml` at the pin](https://github.com/ggml-org/whisper.cpp/blob/927cfce34f31707e17f2bff35c349632fb9e2c3a/.github/workflows/release.yml) |
| LunarG publishes a Windows ARM64 Vulkan SDK 1.4.357.0 (SHA-256 `c10f18a9085018f66e1f50bd60623f17b7081faca165248de54f78728120f334`) | [LunarG SHA record](https://vulkan.lunarg.com/sdk/sha/1.4.357.0/warm/vulkansdk-windows-ARM64-1.4.357.0.exe.json) |

## What the workflow runs

| Job | Runner | What it establishes |
|---|---|---|
| `local-runtime` (reusable `windows-local-runtime.yml`, `architecture: arm64`) | `windows-11-arm` | whisper.cpp 1.9.4 built natively from the pinned commit with clang, CPU only; every DLL must be a native ARM64 image. Cached by pin |
| `native` | `windows-11-arm`, 60 min | Pinned ARM64 Swift 6.2.3; native host check; `swift build`; the production `SpeakWindows.exe` retained before tests (`stage-native-app.py`); `swift test` in release; native image checks of the app, the test executable and the runtime; the three WinHTTP loopback probe suites; `--self-test`, `--ui-smoke-test` (30 s) and on-device JFK transcription with the pinned tiny model, each run observed natively |
| `bundle` | `macos-15`, 30 min | Extracts the Swift runtime from the pinned ARM64 installer with the pinned 7-Zip. Assembles the ARM64 bundle from the `native` job's production executable, that runtime, the ARM64 Visual C++ runtime and the ARM64 whisper.cpp runtime |
| `bundle-execute` | `windows-11-arm`, no Swift, 20 min | `verify-windows-bundle.ps1`: hashes, isolated PATH, `STATUS_DLL_NOT_FOUND` negative control, missing-resource control, loaded-module provenance, on-device transcription from the bundle, and a native ARM64 process for every run |
| `package-lifecycle` | `windows-11-arm`, 45 min | ARM64 developer MSIX (`ProcessorArchitecture="arm64"`, same identity) packed with the pinned MakeAppx. The x64 install, launch, failed-upgrade, upgrade, uninstall and admission-control checks, unchanged |

The x64 workflows keep their runners, jobs and artifact names. The reusable
runtime workflow defaults to x64. The ARM64 jobs are path-filtered like the
x64 ones, cancel superseded pull-request runs, and have explicit timeouts.

## Native execution, not x64 emulation

Windows 11 on ARM runs x64 programs through emulation, so a green run on an
ARM64 runner proves nothing about ARM64 by itself. An x64 toolchain would
build x64 binaries that pass there too. The evidence therefore works at three
levels, recorded in `windows-arm64-native-execution.json` (developer
artifact and test evidence):

1. **Images.** `scripts/windows-bundle/windows_pe.py` reads each PE header's
   machine and the load configuration's CHPE metadata pointer. That pointer is
   what separates ARM64EC (x64 header, ARM64 code for emulated processes) from
   x64, and ARM64X (ARM64 header with an EC view) from plain ARM64. A native
   ARM64 process loads ARM64 and ARM64X images. A native x64 process loads
   only x64. ARM64EC is accepted by neither. Checked against real binaries:
   the x64 bundle of run 35753297969 and the Swift x64 runtime are all x64.
   Swift's `bin64a` test DLLs are ARM64. Microsoft's ARM64 runtime DLLs are
   ARM64X, and its `vcruntime140_1.dll` is ARM64EC.
2. **Host.** `IsWow64Process2` must report an ARM64 native machine. The
   Swift driver and clang images are recorded, not required.
3. **Processes.** `verify-native-execution.py run` starts the program, reads
   the machine Windows reports for that process
   (`GetProcessInformation(ProcessMachineTypeInfo)`, Windows 11), and samples
   its loaded modules until it exits. It fails on any machine but ARM64, on
   any emulator module (`xtajit64.dll`, `xtajit.dll`, WOW64 modules), or on
   any module outside `%SystemRoot%` that is not a native ARM64 image. It also
   requires exit code 0 and the success marker. `verify-windows-bundle.ps1`
   applies the same machine and emulator checks to every bundled run.

An ARM64 image cannot run under emulation on Windows. So native images on a
native host already rule out emulation for the `swift test` run, whose test
process SwiftPM starts; level 3 observes it directly for the application.

## On-device transcription runtime

`scripts/windows-local-runtime/dependencies.json` now pins each architecture.
The x64 arguments, Vulkan SDK and CPU variants are unchanged. ARM64 builds
whisper.cpp 1.9.4 (the same commit, licence and version check) inside Visual
Studio's ARM64 developer environment, with clang targeting
`arm64-pc-windows-msvc` and the shared `/MD` Visual C++ runtime:

- **One CPU backend.** ggml cannot select CPU variants at run time on Windows
  ARM, so ARM64 ships a single `ggml-cpu.dll`. The app's
  `ggml_backend_load_all_from_path` loads it as the base CPU backend.
- **ARMv8-A baseline.** `GGML_CPU_ARM_ARCH=armv8-a` runs on every Windows
  ARM64 PC. It gives up dot-product, FP16 arithmetic and int8 matrix
  instructions. Upstream's toolchain file targets `armv8.7-a` with fast
  floating-point math, which would stop older PCs and change numerics.
  Throughput on real ARM64 PCs has not been measured.
- **No GPU backend (capability gate).** LunarG does publish a Windows ARM64
  Vulkan SDK. It is not pinned here, and ggml-vulkan is not built for ARM64,
  because upstream ships no Windows ARM64 Vulkan build and the hosted ARM64
  runners have no GPU to test one. On ARM64 the app's GPU setting finds no GPU
  backend and uses the CPU. Qualcomm GPU acceleration (Vulkan or upstream's
  OpenCL Adreno backend) needs its own pin, build and physical Snapdragon
  receipt.

## Bundle and developer MSIX

- **Swift runtime.** ARM64 DLLs exist only in the ARM64 installer.
  `pin-swift-runtime.py` finds the Burn cabinets from the installer's
  `.wixburn` header, not from fixed x64 offsets. It authenticates `rtl.msi`
  and `rtl.cab` against the installer's SHA-512 manifest and hashes every DLL
  into a lock. The installer is pinned by SHA-256 and its exact size, and
  `scripts/windows-bundle/swift-runtime-lock-arm64.json` is committed. Each
  run regenerates the lock from the pinned download and fails unless it
  equals the committed lock. The bundle is then assembled against the
  committed lock, and its manifest names it.
- **Visual C++ runtime.** Taken from the same pinned `VC_redist.x64.exe`
  (14.51.36247.0). Its Burn manifest carries
  `packages\VC_Runtime_arm64\VC_Runtime_arm64.msi`, installed only when
  `Arm64_Check` is ARM64. Its 25 ARM64/ARM64X DLLs are the candidates. Its
  ARM64EC `vcruntime140_1.dll` and two x64 MFC shims are recorded as not
  native and are never bundled. Nothing native needs that file: native ARM64
  C++ code takes `__CxxFrameHandler3` from the ARM64X `vcruntime140.dll`.
  `__CxxFrameHandler4`, which the x64 app imports from `vcruntime140_1.dll`,
  exists on ARM64 only in that ARM64EC file, for emulated code.
- **Application.** The production executable staged by the `native` job, with
  `app-build-metadata.json` (host Windows, target
  `aarch64-unknown-windows-msvc`, release, not built for testing). The bundle
  refuses a hash mismatch, an x64 or ARM64EC image, or a test import.
- **Package.** `package-identity.json` lists `x64` and `arm64`. A layout takes
  its architecture from the bundle and re-checks every DLL as a native image.
  The family name is shared; the package full name carries `_arm64_`.
  Windows installs only the package matching the PC. A later `.msixbundle`
  could hold both, but a family cannot move back from a bundle to one `.msix`.

## ARM64 Swift runtime pin

On 23 September 2026 the integrator ran this repository's unchanged
`pin-swift-runtime.py --architecture arm64` against the official download,
with the pinned macOS 7-Zip. The download matched the pinned SHA-256
(`42e1dbfd…f747`) and measured 635,789,872 bytes; that exact size is now the
pin. The installer manifest's SHA-512 digests authenticated `rtl.msi`
(442,368 bytes) and `rtl.cab` (18,034,513 bytes). The script reconstructed 33
files and locked the 32 DLLs; `plutil.exe` is not locked, as for x64. The
committed `swift-runtime-lock-arm64.json` is that generated lock, byte for
byte (SHA-256 `49c082dc10c3ef3f810f644ce3e9d4c1824bc315d25256fc4502ac443469dd55`).

Reviewed independently from the extracted runtime:

- Every locked file re-hashed to its recorded size and SHA-256. The lock
  lists the same 32 DLL names as the x64 lock, all classified by the runtime
  policy: 22 Swift runtime modules and 10 Visual C++ runtime names.
- The 22 Swift runtime DLLs and `plutil.exe` are plain ARM64 images. The
  installer's own copies of the Visual C++ runtime are ARM64X, and its
  `vcruntime140_1.dll` is ARM64EC. Bundles never take those copies: the
  policy sources the Visual C++ runtime from Microsoft's redistributable only.
- Every import of every runtime image is a module the policy classifies, and
  none imports `vcruntime140_1.dll`.
- A dry run of the bundle builder, run locally, used this runtime, the
  committed lock and the pinned ARM64 Visual C++ package. Its application was
  a synthetic ARM64 executable with the real x64 app's imports, less
  `vcruntime140_1.dll`. It assembled 29 files with 16 runtime DLLs: 14 Swift
  DLLs, ARM64X `msvcp140.dll` and `vcruntime140.dll`. Every image was
  recorded as native ARM64. The pinned `llvm-readobj` 20.1.8 confirmed all 17
  import tables, including both ARM64X ones. The real ARM64 executable is
  built only in CI.

This authenticates the pinned inputs; it is not evidence that anything ran on
ARM64.

## Verification in this change

- Python suites on macOS (Python 3.14.4), each also run on the tree of each
  commit: bundle tooling 81 tests (the ARM64 assembly class skips its two
  x64-only cases), whisper.cpp runtime 11, developer MSIX 38, cross-build 14,
  all passing with encoding warnings as errors. They include native execution,
  staging, ARM64 runtime, ARM64 assembly and PE architecture cases. Two of the
  bundle tests came with the runtime pin: each committed lock must name its
  pinned installer exactly and load only for its own architecture, and must
  list only well-formed runtime DLLs the policy classifies. Changing the pinned
  size or SHA-256, restoring `maximumBytes`, or altering the lock's installer,
  architecture, file names or payload digests each fails them. Another checks
  that the `llvm-readobj` cross-check reads only an ARM64X image's native view.
- The generalised extractor regenerated the committed x64
  `swift-runtime-lock.json` from the pinned x64 installer and pinned 7-Zip.
  Every field was byte-identical; the one addition is `"architecture": "x64"`.
- The refactored bundle builder rebuilt the x64 bundle from the executable of
  [run 35753297969](https://github.com/crmitchelmore/justspeaktoit/actions/runs/35753297969),
  with the pinned `llvm-readobj` confirming every import table. 29 of 30 files
  were byte-identical to that run's verified bundle, including all 17 runtime
  DLLs, README and notices. `bundle-manifest.json` differs by the new
  provenance fields and by the runtime policy other work changed since.
- The ARM64 Visual C++ package was read from the real pinned redistributable
  with the bundle builder's own loader.
- Not run here: actionlint (it needed approval in this session; a strict
  structural check of the workflow YAML was used instead; the integrator's
  actionlint run then passed), PowerShell parsing (no PowerShell on the Mac)
  and any Windows ARM64 execution. Those are CI's first receipt.

## Remaining gates

- **First CI receipt** of `windows-arm64.yml` for an exact revision: test and
  skip counts, WinHTTP probes, native-execution evidence, bundle and MSIX
  hashes, and the regenerated ARM64 runtime lock equal to the committed one.
- **Import cross-check in ARM64 CI.** For an ARM64X image, `llvm-readobj`
  also prints the ARM64EC view under `HybridObject`. The cross-check now reads
  only the native view, which a native ARM64 process loads and `windows_pe.py`
  reads; before, it rejected Microsoft's ARM64X runtime. It passed the local
  ARM64 dry run above and still runs for x64. CI's ARM64 bundle job does not
  run it: that job has no pinned LLVM, and adding one waits for the first
  ARM64 receipt.
- **GPU inference on ARM64** (Vulkan or OpenCL Adreno), and CPU feature
  levels above ARMv8-A. These need a verified dispatch and physical-device
  measurements.
- **Performance.** Cold start, capture, WebSocket, transcription throughput and
  memory on physical ARM64 PCs, compared with the x64 build under emulation.
- **Physical acceptance** on Snapdragon PCs: microphones, playback devices,
  insertion into real applications, and install, upgrade and uninstall
  without development tools.
- **iCloud sync token.** Only the x64 Mac cross-build receives the CloudKit Web
  Services token on `main`. Native ARM64 builds report iCloud sync as
  unavailable.
- **Signing and distribution.** The Artifact Signing job signs x64 only. There
  is no ARM64 signing, `.msixbundle`, updater or Alpha/Stable Windows surface.
- **`speak.exe`** is not built into or packaged with either architecture's
  bundle.

## Commands

Local, on any host:

```sh
python3 -B -m unittest discover -s scripts/windows-bundle -p 'test_*.py'
python3 -B -m unittest discover -s scripts/windows-local-runtime -p 'test_*.py'
python3 -B -m unittest discover -s scripts/windows-package -p 'test_*.py'
```

On a Windows ARM64 machine with the ARM64 Swift 6.2.3 toolchain:

```powershell
swift build --configuration release --product SpeakWindows
$bin = (swift build --configuration release --show-bin-path).Trim()
python -B scripts/windows-bundle/stage-native-app.py --architecture arm64 --bin-path $bin --output windows-arm64-app
python -B scripts/windows-bundle/verify-native-execution.py --architecture arm64 --evidence native.json host
python -B scripts/windows-bundle/verify-native-execution.py --architecture arm64 --evidence native.json `
  run --label self-test --timeout 90 --stdout self-test.log --stderr self-test-errors.log `
  --expect-output 'self-test passed' -- windows-arm64-app\SpeakWindows.exe --self-test
```

To regenerate the ARM64 runtime lock on a Mac and require it to equal the
committed one (downloads the 636 MB installer and the pinned 7-Zip):

```sh
python3 -B scripts/windows-bundle/pin-swift-runtime.py --architecture arm64 \
  --downloads /path/to/private/arm64-downloads --temporary-parent /path/to/private \
  --output /path/to/private/swift-runtime-lock-arm64.json \
  --runtime-output /path/to/private/swift-runtime-arm64 \
  --compare scripts/windows-bundle/swift-runtime-lock-arm64.json
```
