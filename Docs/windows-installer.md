# Windows developer MSIX package

This is the first installer slice for Windows x64: an **unsigned developer
MSIX package** built from the verified self-contained runtime bundle with
Microsoft's MakeAppx, plus a lifecycle test that signs it with an ephemeral
certificate on a disposable CI runner and installs, launches, upgrades and
uninstalls it. It is not an Alpha or Stable release, not signed for
distribution, not an updater and not an ARM64 package. No install receipt
exists until the `package-lifecycle` job has passed for a revision (see
[Evidence](#evidence-at-this-checkpoint)).

## Identity and version

`scripts/windows-package/package-identity.json` is the only Windows package
identity in the repository.

| Field | Value |
|---|---|
| Package name | `com.justspeaktoit.windows.developer` |
| Default publisher | `CN=Just Speak to It Developer` (placeholder for the unsigned package) |
| Package family | `com.justspeaktoit.windows.developer_12qtdfzdxrxs0` for the default publisher |
| Application / AUMID | `JustSpeakToIt` / `<family>!JustSpeakToIt` |
| Display name | Just Speak to It Developer |
| Execution alias | `JustSpeakToItDeveloper.exe` |
| Architecture | x64 only |
| Target | `Windows.Desktop`, minimum 10.0.19041.0, tested 10.0.20348.0 (the CI runner build) |
| Capabilities | `runFullTrust`, `unvirtualizedResources` (restricted), `microphone` (device) |
| Payload | Every file of the verified runtime bundle, byte for byte (including its `README.txt`, which describes the portable bundle), plus `AppxManifest.xml`, three logos and `package-manifest.json` |

The family name is Windows' hash of the publisher. The builder computes it
(checked against Microsoft's published `8wekyb3d8bbwe` and `cw5n1h2txyewy`
IDs) and the lifecycle test requires Windows to report the same value.

**Release trains.** [Alpha and Stable](alpha-stable-release-trains.md) define
Mac and iOS surfaces only; `ReleaseTrains.json` has no Windows identity and
`ReleasePipeline.json` no Windows version. This developer identity is
deliberately outside both trains: a unit test refuses any overlap with train
identifiers. The layout builder never derives a version from `VERSION`,
`BUILD_NUMBER`, tags or the train manifest; callers pass an explicit
four-part version. CI uses `0.0.<workflow run number>.1` and `.2` for its
two lifecycle packages and uploads the `.2` package. These numbers only order
developer builds. Nothing here publishes, tags, changes release commissioning
or touches a Stable feed.

## File system and user data

The app keeps settings, History records and recordings in
`%LOCALAPPDATA%\JustSpeakToIt`, taken from its `LOCALAPPDATA` environment
value; credentials are Windows Credential Manager entries named
`com.justspeaktoit/<provider credential>`.

By default Windows virtualises a packaged desktop app's AppData writes: new
files and folders go to a per-package private location that is merged into
the app's view and deleted on uninstall
([Microsoft](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes)).
On a fresh machine, the app's entire History would live there and be lost on
uninstall; on a machine with portable data it would write in place. The
package therefore declares `desktop6:FileSystemWriteVirtualization` =
`disabled`, which needs the `unvirtualizedResources` restricted capability
([element](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-desktop6-filesystemwritevirtualization),
[capability](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations)).
The resulting contract:

- The installed app reads and writes the same real directory as the portable
  bundle. Existing portable data is used in place: nothing is copied, moved or
  migrated, and nothing is left in package-private storage.
- Install, upgrade, failed or cancelled deployment and uninstall never modify
  that directory. Uninstall removes the program files, Start menu entry, alias
  and the package-private `%LOCALAPPDATA%\Packages\<family>` folder only. Data
  must be deleted by the user if wanted.
- The portable bundle and the installed package are the same developer app and
  share that directory. Running both at the same time is not supported.
- `desktop6` is intentionally absent from `IgnorableNamespaces`, so an OS that
  could not honour the setting refuses the package instead of silently
  virtualising. Registry write virtualisation stays enabled: the app writes no
  registry values, and shell or dialog state Windows records in HKCU stays per
  package and is removed on uninstall.
- Microsoft describes `unvirtualizedResources` as intended for specific
  scenarios. Sideloading needs no approval; a Store submission would need
  approval or a different data design.
- Credential Manager entries are stored by the system credential service, not
  in package state. The lifecycle test shows the installed app reading
  Credential Manager without error (it reports no saved key); it does not
  create a credential, so credential retention across upgrade and uninstall
  is by design only and remains an acceptance item.

## Install, upgrade, failure and uninstall

Installation is per user. The package registers a Start menu entry with the
display name, an Installed apps entry with Uninstall, and the execution alias.
An upgrade needs the same family and a higher version; Windows installs it to
a new directory and removes the old one. MSIX deployment is transactional: a
failed or cancelled deployment leaves the previous registration in place.
The lifecycle test checks each case below rather than relying on that
statement.

The executable uses the console subsystem (as the portable bundle does), so a
Start menu launch also opens a console window. Changing the linker subsystem
is a production build change in `Package.swift`, outside this slice.

## Signing

- **Unsigned developer package** (`windows-developer-msix-unsigned`). Windows
  installs only signed packages through Add-AppxPackage or App Installer. The
  Windows 11 unsigned-package route needs a special publisher OID that gives a
  different identity, so it is not used.
- **Externally supplied signing configuration.** The owner provides a code
  signing certificate in a Windows certificate store (a hardware token or key
  storage provider may hold its key). Rebuild the layout with
  `--publisher "<certificate subject>"`, pack it, then run
  `sign-windows-package.ps1 -CertificateThumbprint <sha1> -TimestampUrl <RFC 3161 URL>`.
  The script checks that the subject equals the manifest publisher, the code
  signing EKU and validity, signs a copy with the pinned SignTool and proves the
  payload and block map are unchanged. A new publisher is a new package family:
  choose it once. A certificate from a CA in Windows' trusted roots installs
  without extra trust steps; a self-signed one must be imported into each
  machine's Trusted People store and is suitable only for testing. Choosing,
  buying or enrolling a signing identity, and any timestamp service, are owner
  decisions. No signing material, thumbprint or secret is in this repository.
- **CI test certificate.** The lifecycle job creates a NonExportable,
  three-hour self-signed certificate in the runner's user store, trusts only
  its public part in `LocalMachine\TrustedPeople`, signs through the same
  script and removes certificate, key and trust before the job ends. A second
  untrusted certificate provides a negative control. Signed test packages are
  not uploaded.

## Tooling and provenance

- MakeAppx and SignTool come from Microsoft's `Microsoft.Windows.SDK.BuildTools`
  10.0.26100.1 NuGet package, pinned by SHA-512 and size from the nuget.org
  catalog in `scripts/windows-package/dependencies.json`. Only its x64 tool
  directory is extracted, and both tools must carry valid Microsoft signatures.
  The Windows SDK is not shipped.
- `build-windows-package-layout.py` authenticates the bundle exactly as the
  bundle job recorded it: archive hash and size, manifest hash, every file
  hash, source commit, an optimised production executable without test
  imports, the repository's runtime policy, forbidden files, reserved package
  paths and file names. It reuses the bundle builder's policy, path and PE
  code rather than a second dependency list.
- MakeAppx runs with full validation and a SHA-256 block map.
  `verify-windows-package.py` then independently reads the package and requires
  exactly the layout's files and bytes with correct block hashes; after signing
  it requires the same block map, adding only `AppxSignature.p7x`.
- Logos are exact integer area averages of
  `Resources/AppIcon.iconset/icon_256x256.png`, so every host produces the same
  pixels. They carry no scale variants or resource index yet.

## Commands

```sh
python3 -B -m unittest discover -s scripts/windows-package -p 'test_*.py'
python3 -B scripts/windows-package/build-windows-package-layout.py \
  --bundle /path/to/windows-runtime-bundle --expected-commit <commit> \
  --version 0.0.1.1 --output /path/to/package-output
```

On Windows (Windows PowerShell 5.1 or PowerShell 7 for packing and signing):

```powershell
./scripts/windows-package/pack-windows-package.ps1 -Layout package-output\layout `
  -Output out\JustSpeakToIt-Developer_0.0.1.1_x64_unsigned.msix -ToolCache $env:TEMP\jsti-packaging-tools
```

`test-windows-package-lifecycle.ps1` refuses to run outside a GitHub-hosted
runner unless `-DisposableMachine` is passed on a throwaway VM, and refuses
any machine that already has the app's data, package, alias or a certificate
with its publisher.

## Continuous integration

The `package-lifecycle` job in `windows-cross-proof.yml` runs on `windows-2022`
after the Mac cross-build and needs no Swift installation. It runs the Python
tests, builds base and upgrade layouts from the bundle artifact, packs both,
uploads the unsigned upgrade package, and then, under Windows PowerShell:

1. Refuses a tampered package on a fresh machine.
2. Installs the base version; checks its registration, identity, signature
   kind, installed files, Start menu entry and alias.
3. Runs `--bundle-self-test` (with the loaded-module handshake), `--self-test`
   and `--ui-smoke-test` through the alias, requiring the process to carry the
   installed package identity and to load the runtime only from the package.
4. Launches through the Start menu activation (AUMID), waits for the window,
   reads its status, History list and transcript controls, checks identity and
   loaded modules, and closes it with `WM_CLOSE`.
5. Confirms a fresh launch writes the real `%LOCALAPPDATA%\JustSpeakToIt` and
   nothing to package-private AppData, uninstalls, and confirms that data
   survives.
6. Seeds a synthetic portable-install fixture in the app's formats: settings,
   a completed record and WAV, an interrupted record whose WAV header has zero
   lengths, and unknown user files. An untrusted package is refused. The base
   version installs, shows both records and the fixture transcript, and
   recovers the interrupted record in the real directory without changing any
   audio sample or other file.
7. With the base installed, a cancelled upgrade, a tampered upgrade, an
   untrusted upgrade and an upgrade while the app runs (expected
   `ERROR_PACKAGES_IN_USE`) each leave the previous registration, its
   installed files and all user data unchanged; the base still launches with
   its History. The same upgrade package then installs, so each refusal is
   attributable to its injected fault.
8. The upgrade installs in the same family at a new location, passes its
   bundle self-test and launch, and keeps all data.
9. Uninstall removes the registration, Start menu entry, alias and package
   data and keeps every user file; a reinstall shows the History again and is
   uninstalled.

The job always uploads `windows-developer-msix-lifecycle-evidence`: every
check, deployment result with HRESULT and deployment log, launch state,
module provenance, runner facts (build, integrity, UAC settings) and cleanup,
including removal of both test certificates.

## Evidence at this checkpoint

- Locally on macOS (Python 3.14.4), 28 packaging unit tests pass. They cover
  schema rules, publisher IDs, manifest content and escaping, deterministic
  logos, refusal of changed or foreign bundles, same-size tampering,
  test-enabled builds, policy and reserved-path violations, layout
  determinism, block-map verification including multi-block files, fixture
  formats, recovery checks and single-byte tampering.
- Package-only local check: the layout was built from the Windows-verified
  bundle artifact of [run 35753297969](https://github.com/crmitchelmore/justspeaktoit/actions/runs/35753297969)
  (ZIP SHA-256 `2e92ec9c2e95ec891cc17ad22b79e6d5e00f88394d4dc01e50f64eb5cedf3316`,
  commit `386ddeb5`): 35 files, the 30 bundle files unchanged. The logos were
  inspected visually.
- **Not yet executed:** MakeAppx packing, signing, and every Windows
  install, launch, failure, upgrade and uninstall step. They run only in the
  `package-lifecycle` job, which has not run for this revision. No installation
  receipt exists yet.

## Remaining gates and integration needs

- **ARM64 (same issue, next slice).** Needs an arm64 cross build and bundle:
  arm64 Swift runtime DLLs and lock, the arm64 Visual C++ runtime from its
  pinned redistributable, a per-architecture runtime policy, a package with
  `ProcessorArchitecture="arm64"` or an `.msixbundle` for both architectures
  (a family may move from `.msix` to a bundle, not back), and execution on an
  arm64 Windows runner. Nothing here claims arm64 support.
- **Updater (same issue, later slice).** Needs a stable, externally signed
  publisher first. MSIX updates can use an `.appinstaller` file over HTTPS
  with update settings, or an in-app check through the PackageManager API;
  both need a hosting location and a channel decision. Any Alpha or Stable
  Windows channel must first be defined in the release-train manifest. The
  package declares no update behaviour today.
- **Release identities.** Train-specific Windows identities also need
  train-specific data directories in the app, like Apple's
  `applicationSupportDirectory`; today every Windows build shares
  `JustSpeakToIt`. That is an app change requiring coordination.
- **Acceptance not covered by CI.** A clean physical Windows 10 and Windows 11
  machine without development tools; the App Installer double-click flow (not
  present on the Server runner); SmartScreen and reputation for a signed
  build; the microphone consent prompt under the package identity; saving,
  using and removing a real credential across upgrade and uninstall; high-DPI
  logos with scale variants and a resource index; and the console window.
