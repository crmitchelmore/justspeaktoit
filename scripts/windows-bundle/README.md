# Self-contained Windows developer runtime bundle

`build-windows-bundle.py` turns a production Windows build into a deterministic
ZIP that runs on Windows 10 or later without a Swift toolchain or a separately
installed Visual C++ redistributable. It copies the production
`SpeakWindows.exe`, its SwiftPM resources, and only the runtime DLLs reached
from the executable's static and delay-load import closure, plus licence texts
and a manifest of hashes and provenance. Every executable and DLL must be an
image a native process of the bundle's architecture loads (`windows_pe.py`
tells x64, ARM64, ARM64EC and ARM64X apart). `verify-windows-bundle.ps1` runs
that bundle on Windows with an isolated PATH and records sampled loaded
modules and, for ARM64, the machine of each process.

| Architecture | Application | Swift runtime | Visual C++ runtime |
|---|---|---|---|
| x64 (default) | Mac cross-build (`build-windows-app.py`) | Cross-build cache, committed `swift-runtime-lock.json` | x64 package of the pinned `VC_redist.x64.exe` |
| ARM64 | Native Windows ARM64 build (`stage-native-app.py`) | `pin-swift-runtime.py --architecture arm64 --runtime-output` from the pinned ARM64 installer | ARM64 package inside the same pinned `VC_redist.x64.exe` |

`verify-native-execution.py` records, on Windows, that a host and the programs
it runs are native for an architecture rather than emulated.

Design, provenance, licences, evidence and remaining gates are documented in
[Docs/windows-runtime-bundle.md](../../Docs/windows-runtime-bundle.md) and, for
ARM64, [Docs/windows-arm64.md](../../Docs/windows-arm64.md).

```sh
python3 -B -m unittest discover -s scripts/windows-bundle -p 'test_*.py'
python3 scripts/windows-bundle/build-windows-bundle.py \
  --app /path/to/windows-app-cross \
  --cache /path/to/private/windows-cross-sdk \
  --downloads /path/to/private/bundle-downloads \
  --output /path/to/windows-runtime-bundle
python3 scripts/windows-bundle/pin-swift-runtime.py --architecture arm64 \
  --downloads /path/to/private/arm64-downloads --temporary-parent /path/to/private \
  --output /path/to/swift-runtime-lock-arm64.json --runtime-output /path/to/swift-runtime-arm64
python3 scripts/windows-bundle/build-windows-bundle.py --architecture arm64 \
  --app /path/to/windows-arm64-app \
  --swift-runtime /path/to/swift-runtime-arm64 --swift-runtime-lock /path/to/swift-runtime-lock-arm64.json \
  --downloads /path/to/private/bundle-downloads \
  --local-runtime /path/to/windows-local-runtime-arm64 \
  --output /path/to/windows-runtime-bundle-arm64
```
