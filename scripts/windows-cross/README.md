# macOS → Windows Swift app builds

This isolated workflow cross-compiles the Windows app, its shared Swift code,
native C++ adapters and XCTest suite on an Apple Silicon Mac. Windows then runs
the Mac-built tests, native self-tests and native window smoke checks. It also
keeps a small Foundation proof to distinguish SDK failures from app failures.
These build and runtime checks do not establish complete feature parity or
physical microphone/device acceptance.

The source checks Swift arrays, Unicode, Codable JSON, Foundation regular
expressions, URLs and atomic file write/read operations. The Windows job must
exit successfully and print `JSTI_FOUNDATION_WINDOWS_CROSS_PROOF_OK`.

Run on macOS:

```sh
python3 scripts/windows-cross/build-foundation-proof.py \
  --cache /path/to/private/windows-cross-sdk \
  --output /path/to/foundation-proof
python3 scripts/windows-cross/build-windows-app.py \
  --cache /path/to/private/windows-cross-sdk \
  --output /path/to/windows-app-cross
```

`--scratch-path` moves SwiftPM intermediates out of the default `CACHE/app-build`;
it must stay outside the output and must not contain the cache. `--jobs` sets
SwiftPM parallelism (default 4). Neither option changes the build provenance.

The app script defaults to optimised `release` builds and records the configuration
in its provenance; `--configuration debug` is available for debugging. CI requires
release configuration for both the app and tests. It first retains the normal
application binary, then enables testable imports for the separate XCTest build;
the app artifact is never replaced by the test-enabled build. The script preserves the exact
existing Apple `Package.resolved` bytes and permissions, including uncommitted
pins, even if SwiftPM fails. No initial lockfile means no lockfile is left behind.

The cache and outputs must be separate directories. Expect approximately 4.4 GB
of downloads and around 11 GB retained after task-owned extraction staging is removed.
Allow extra space for peak extraction and both build configurations. Every download has a fixed
official URL, SHA-256 and actual byte count in `dependencies.json`. The Swift
Windows installer is unpacked as data; its MSI custom actions never execute.
The extracted macOS compiler is used by absolute path, with no global toolchain
installation, shell changes or `swift sdk install` registration.

`SPEAK_WINDOWS_TARGET=1` selects the Windows SwiftPM product graph explicitly
because manifest `#if os(Windows)` evaluates on the Mac host. It is set only for
the cross-build subprocess. Without it, the normal Apple package graph remains
unchanged. The app script supplies the Windows target triple, matching SDK and
link libraries, plus the SDK's XCTest/Testing module paths.

The C++ adapters use a separately pinned official LLVM 20.1.8 compiler. The
Clang 17 bundled with Swift 6.2.3 cannot compile the pinned Microsoft C++ standard
library; its minimum compiler check fails. The build uses the compatible
compiler instead of bypassing that check. Only required LLVM tools, resource
headers and notices are extracted from its archive.

The matching official Swift 6.2.3 compiler is necessary for Windows Foundation's
binary Swift module. The Xcode 6.2.3 compiler successfully rebuilt the Windows
standard library from its interface but rejected Foundation's binary module as
having been produced by another compiler. Normal Apple app builds continue to
use Xcode's compiler.

The pinned Swift module maps are copied unchanged beside the corresponding
Microsoft headers, as the Windows installation normally does. Microsoft include
roots are passed through Swift `-I` so nested Swift interface compilation inherits
them. Passing only `-Xcc -isystem` did not preserve those roots in this probe.

Prerequisites are acquired for this MIT-licensed open-source application's build
under the linked Swift, Windows SDK, Visual Studio Community OSS, LLVM and 7-Zip terms.
Keep the prerequisite cache private. Do not upload or redistribute Microsoft
headers, libraries, SDKs or compiler packages in build artifacts. The Windows CI
job installs Swift 6.2.3 through the existing pinned setup action and runs only
the executables produced by the Mac job. SwiftPM resource directories accompany
the app and tests. The runtime artifact includes test logs and a snapshot of the
app's synthetic smoke-test window; it never captures the desktop or other apps.

The lock records a Microsoft metadata inconsistency observed on 22 September
2026: catalogue outer digests and advertised sizes did not match downloaded
catalogue bytes; individual CRT package digests matched their official URL and
payload hash. This workflow does not fetch those mutable catalogues. It checks
the pinned actual package hashes and sizes directly and refuses a mismatch.
