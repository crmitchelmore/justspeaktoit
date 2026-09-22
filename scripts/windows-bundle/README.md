# Self-contained Windows developer runtime bundle

`build-windows-bundle.py` turns the Mac cross-build output into a deterministic
ZIP that runs on 64-bit Windows 10 or later without a Swift toolchain or a
separately installed Visual C++ redistributable. It copies the production
`SpeakWindows.exe`, its SwiftPM resources, and only the runtime DLLs reached
from the executable's static and delay-load import closure, plus licence texts
and a manifest of hashes and provenance. `verify-windows-bundle.ps1` runs that
bundle on Windows with an isolated PATH and records sampled loaded modules.

Design, provenance, licences, evidence and remaining gates are documented in
[Docs/windows-runtime-bundle.md](../../Docs/windows-runtime-bundle.md).

```sh
python3 -B -m unittest discover -s scripts/windows-bundle -p 'test_*.py'
python3 scripts/windows-bundle/build-windows-bundle.py \
  --app /path/to/windows-app-cross \
  --cache /path/to/private/windows-cross-sdk \
  --downloads /path/to/private/bundle-downloads \
  --output /path/to/windows-runtime-bundle
```
