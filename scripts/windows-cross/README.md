# macOS → Windows Swift Foundation proof

This isolated check establishes that a Mac can compile and link an actual
Windows Swift executable using `Foundation`, then verifies its behaviour on
Windows. It does not establish that the complete app cross-compiles or that
Windows feature parity is finished.

The source checks Swift arrays, Unicode, Codable JSON, Foundation regular
expressions, URLs and atomic file write/read operations. The Windows job must
exit successfully and print `JSTI_FOUNDATION_WINDOWS_CROSS_PROOF_OK`.

Run on macOS:

```sh
python3 scripts/windows-cross/build-foundation-proof.py \
  --cache /path/to/private/windows-cross-sdk \
  --output /path/to/foundation-proof
```

The cache and output must be separate directories. Expect approximately 3 GB of
downloads and additional space for extraction. Every download has a fixed
official URL, SHA-256 and actual byte count in `dependencies.json`. The Swift
Windows installer is unpacked as data; its MSI custom actions never execute.
The extracted macOS compiler is used by absolute path, with no global toolchain
installation, shell changes or `swift sdk install` registration.

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
under the linked Swift, Windows SDK, Visual Studio Community OSS and 7-Zip terms.
Keep the prerequisite cache private. Do not upload or redistribute Microsoft
headers, libraries, SDKs or compiler packages in build artifacts. The Windows CI
job installs Swift 6.2.3 through the existing pinned setup action and runs only
the executable produced by the Mac job.

The lock records a Microsoft metadata inconsistency observed on 22 September
2026: catalogue outer digests and advertised sizes did not match downloaded
catalogue bytes; individual CRT package digests matched their official URL and
payload hash. This workflow does not fetch those mutable catalogues. It checks
the pinned actual package hashes and sizes directly and refuses a mismatch.
