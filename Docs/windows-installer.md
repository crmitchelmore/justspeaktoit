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
  different identity, so it is not used. Every CI run still produces it.
- **Azure Artifact Signing in CI** (`windows-developer-msix-signed`). When the
  secrets and variables below exist, the `sign` job signs a separately built
  copy; see [Setting up Azure Artifact Signing](#setting-up-azure-artifact-signing).
  Without them the job logs "Azure Artifact Signing is not configured ...
  keeping the unsigned developer MSIX" and succeeds; a partial setup fails and
  names the missing settings.
- **Certificate in a Windows certificate store.** For an OV certificate on a
  token or cloud HSM, rebuild the layout with
  `--publisher "<certificate subject>"`, pack it, then run
  `sign-windows-package.ps1 -CertificateThumbprint <sha1> -TimestampUrl <RFC 3161 URL>`.
  The script checks that the subject equals the manifest publisher, the code
  signing EKU and validity, signs a copy with the pinned SignTool and proves the
  payload and block map are unchanged. A self-signed certificate must be
  imported into each machine's Trusted People store and is suitable only for
  testing. No signing material, thumbprint or secret is in this repository.
- **CI test certificate.** The lifecycle job creates a NonExportable,
  three-hour self-signed certificate in the runner's user store, trusts only
  its public part in `LocalMachine\TrustedPeople`, signs through the same
  script and removes certificate, key and trust before the job ends. A second
  untrusted certificate provides a negative control. Signed test packages are
  not uploaded.

A new publisher is a new package family, so choose the signing identity once:
changing it later means users uninstall and reinstall (or a
[persistent identity](https://learn.microsoft.com/windows/msix/package/persistent-identity)
migration).

### Choosing a signing route (September 2026)

| Route | Price | Who can use it | Notes |
|---|---|---|---|
| [Azure Artifact Signing](https://learn.microsoft.com/azure/artifact-signing/overview) (formerly Trusted Signing) | Basic $9.99/month (5,000 signatures, one profile of each type); Premium $99.99/month (100,000, ten); $0.005 per extra signature ([pricing](https://azure.microsoft.com/pricing/details/artifact-signing/)) | Public Trust: organisations in the US, Canada, EU, UK, Australia, New Zealand, Japan, South Korea, Singapore, Switzerland, Norway and Israel; individual developers in the US and Canada only ([prerequisites](https://learn.microsoft.com/azure/artifact-signing/quickstart#prerequisites)). Needs a paid (not free or trial) Azure subscription | Keys in FIPS 140-3 Level 3 HSMs, short-lived certificates renewed automatically, no token, GitHub OIDC. Subject is the validated legal name; no custom CN or O. Not EV |
| [Microsoft Store](https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options) (Partner Center) | Free registration for individuals and companies | Worldwide | The Store re-signs the MSIX after certification. Store distribution only: it does not sign a package you host yourself |
| OV certificate on a token or cloud HSM (for example [Certum](https://www.certum.eu/en/code-signing-certificates/) Open Source Code Signing, SSL.com eSigner, DigiCert KeyLocker) | Certum Open Source from about EUR 25 a year, plus about EUR 85 once for a card and reader if not using its cloud HSM; commercial OV about $150 to $300 a year | Worldwide; Certum's Open Source certificate is issued to individuals who maintain open-source projects | Private keys must live on hardware (CA/Browser Forum, June 2023). Signs through `sign-windows-package.ps1`; cloud HSMs that need interactive 2FA suit local signing better than CI |
| EV certificate | $400+ a year | Worldwide | Since 2024 EV no longer bypasses SmartScreen reputation, so it offers nothing extra here |
| [SignPath Foundation](https://signpath.org/) | Free for qualifying open-source projects | OSI-licensed, released, actively maintained projects | Signs through SignPath's pipeline with the Foundation's certificate, so the publisher is SignPath Foundation rather than the project owner |

**Recommendation: Azure Artifact Signing, Basic tier.** For an open-source
indie shipping an MSIX outside the Store it is the cheapest publicly trusted
route (about $120 a year), keeps the key off every machine, works from
GitHub Actions with no stored secret, and SmartScreen treats it like OV. It is
available if the publisher is an organisation in one of the listed countries
(a UK limited company qualifies) or an individual in the US or Canada. An
individual elsewhere, for example a sole developer in the UK, cannot use it.

**Fallback: an OV code signing certificate in a cloud HSM or on a token**,
for example Certum's Open Source Code Signing certificate for an individual
maintainer, signed locally through `sign-windows-package.ps1`. If the project
prefers not to hold any certificate, SignPath Foundation is the free OSS
alternative, at the cost of its name as publisher. The Store is the right
choice only if Windows builds are to be distributed through the Store.

SmartScreen may still warn on the first downloads of any newly signed build;
reputation builds as consecutive releases are signed with the same identity.

### Setting up Azure Artifact Signing

Do these once, in this order. Only the portal can complete identity validation.

1. **Azure subscription.** Sign in at <https://portal.azure.com> with the
   account that will own the service and create a pay-as-you-go subscription
   (free, trial and sponsored subscriptions are refused). For individual
   validation, the subscription's billing account must be of type Individual
   and its legal name and sold-to address must match your government ID.
2. **Register the provider.** Subscriptions > your subscription > Resource
   providers > `Microsoft.CodeSigning` > Register (or
   `az provider register --namespace Microsoft.CodeSigning`).
3. **Create the account.** Search for Artifact Signing Accounts > Create. Pick
   a resource group, a globally unique account name (3 to 24 letters, digits or
   hyphens), a region near you (for example West Europe, endpoint
   `https://weu.codesigning.azure.net`) and the **Basic** pricing tier. The
   account's Overview shows its **Account URI**: that is the endpoint.
4. **Give yourself the verifier role.** On the account, Access control (IAM) >
   Add role assignment > **Artifact Signing Identity Verifier** > your user.
5. **Validate your identity.** Account > Objects > Identity validations > New
   identity > **Public**, choosing **Organization** (legal name, website,
   primary and secondary email on the organisation's domain, business
   identifier, address, and the representative's name as on their ID) or
   **Individual** (filled from the billing account). Confirm the verification
   email within seven days; for Individual, and for the organisation's
   representative, complete the Verified ID flow (AU10TIX document and face
   check, then Microsoft Authenticator). Organisation validation takes 1 to 20
   business days. Wait for **Completed**.
6. **Create the certificate profile.** Account > Objects > Certificate
   profiles > Create > **Public Trust**, a name of 5 to 100 letters, digits or
   hyphens, and the completed validation under Verified CN and O. Copy the
   **Certificate Subject Preview** exactly, for example
   `CN=Example Ltd, O=Example Ltd, L=Leeds, S=West Yorkshire, C=GB`. That
   string is `WINDOWS_MSIX_PUBLISHER`.
7. **Create the Entra app for GitHub.** Microsoft Entra ID > App registrations >
   New registration, for example `justspeaktoit-windows-signing`, single
   tenant, no redirect URI. Note its **Application (client) ID** and
   **Directory (tenant) ID**. Do not create a client secret.
8. **Trust this repository's signing environment (OIDC).** In the app:
   Certificates & secrets > Federated credentials > Add credential > GitHub
   Actions deploying Azure resources: organisation `crmitchelmore`, repository
   `justspeaktoit`, entity type **Environment**, environment `windows-signing`.
   The subject becomes
   `repo:crmitchelmore/justspeaktoit:environment:windows-signing` with audience
   `api://AzureADTokenExchange`. Only jobs in that environment can sign in.
9. **Let the app sign.** On the certificate profile (or the account), Access
   control (IAM) > Add role assignment > **Artifact Signing Certificate
   Profile Signer** > the app from step 7. Give it no other role.
10. **Create the GitHub environment.** Repository Settings > Environments > New
    environment `windows-signing`. Restrict deployment branches to `main`, and
    add yourself as a required reviewer if every signature should wait for
    approval.
11. **Add the settings** to that environment (or to the repository):

    | Kind | Name | Value |
    |---|---|---|
    | Secret | `AZURE_ARTIFACT_SIGNING_CLIENT_ID` | Application (client) ID from step 7 |
    | Secret | `AZURE_ARTIFACT_SIGNING_TENANT_ID` | Directory (tenant) ID from step 7 |
    | Secret | `AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID` | Subscription ID from step 1 |
    | Variable | `AZURE_ARTIFACT_SIGNING_ENDPOINT` | Account URI from step 3, for example `https://weu.codesigning.azure.net` |
    | Variable | `AZURE_ARTIFACT_SIGNING_ACCOUNT` | Account name from step 3 |
    | Variable | `AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE` | Profile name from step 6 |
    | Variable | `WINDOWS_MSIX_PUBLISHER` | Certificate subject from step 6, character for character |

    The IDs are not credentials, but keeping them as secrets keeps them out of
    logs. The CI never holds a password, client secret or private key.
12. **Run it.** Actions > macOS to Windows Swift Proof > Run workflow on `main`
    (or push to `main`). The `sign` job validates the settings, signs in with
    OIDC, builds a layout whose publisher is `WINDOWS_MSIX_PUBLISHER`, packs it,
    signs a copy with the pinned SignTool and the pinned
    `Microsoft.ArtifactSigning.Client` dlib, timestamps it at
    `http://timestamp.acs.microsoft.com`, checks that the signer subject equals
    the publisher and that the package still equals the verified layout, and
    uploads `windows-developer-msix-signed` with the `.sign.json` receipt.

If signing fails with `0x8007000B`, `WINDOWS_MSIX_PUBLISHER` differs from the
certificate subject; a 403 usually means the role in step 9 is missing or the
identity validation is not Completed. To stop signing, delete the three
secrets and four variables: CI returns to the unsigned package.

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
runner unless `-DisposableMachine` is passed on a throwaway VM. It is then
admitted only if none of these exist: the app's data directory, a registration
of the package name for any user, the package data folder, the alias, a
`SpeakWindows` process or a certificate with the package publisher. Every
admission probe is read-only. A refused run changes nothing, and its cleanup
is skipped. An admitted run records in `LifecycleOwnership.ps1`'s ledger each
package full name it deploys, each process it starts, each certificate it
creates and the data directory it proved absent. Cleanup removes exactly
those, leaves any other registration in place (and fails the run if one
appeared), and fails the run if any owned state cannot be removed.

## Continuous integration

The `package-lifecycle` job in `windows-cross-proof.yml` runs on `windows-2022`
after the Mac cross-build and needs no Swift installation. It runs the Python
tests and `test-lifecycle-ownership.ps1` under PowerShell 7 and again under
Windows PowerShell before the lifecycle. That test drives the real admission
and cleanup rules against a fake machine and changes nothing real. The job
builds base and upgrade layouts from the bundle artifact, packs both, uploads
the unsigned upgrade package, and then, under Windows PowerShell:

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
   attributable to its injected fault. The tampered byte is in a file the
   upgrade changes (the versioned package manifest). Windows reuses installed
   files whose block hashes match, so CI installed an upgrade whose tampered
   byte sat in an unchanged file: that byte was never read.
8. The upgrade installs in the same family at a new location, passes its
   bundle self-test and launch, and keeps all data.
9. Uninstall removes the registration, Start menu entry, alias and package
   data and keeps every user file; a reinstall shows the History again and is
   uninstalled.
10. Cleanup removes only ledger-owned state and must complete.

A final step, `test-windows-package-admission.ps1`, is a negative control for
the lifecycle test itself. After its own pristine admission it installs the
base version with its own ephemeral certificate, seeds the portable data and
leaves the installed app running with its History open. It then runs the
lifecycle test in a child Windows PowerShell (`-NoProfile -NonInteractive
-File`, under the runner's normal execution policy). The test must refuse
admission, skip cleanup and exit non-zero.
The registration and version, the running app and its window, the user data,
alias, package data and certificates must be unchanged. The control then
removes only what it created.

The job always uploads `windows-developer-msix-lifecycle-evidence`: every
check, deployment result with HRESULT and deployment log, launch state,
module provenance, runner facts (build, integrity, UAC settings), the
admission decision, the cleanup record, and the admission control's evidence
with the refused run's own evidence.

## Evidence at this checkpoint

- Locally on macOS (Python 3.14.4), 28 packaging unit tests pass. They cover
  schema rules, publisher IDs, manifest content and escaping, deterministic
  logos, refusal of changed or foreign bundles, same-size tampering,
  test-enabled builds, policy and reserved-path violations, layout
  determinism, block-map verification including multi-block files, fixture
  formats, recovery checks and single-byte tampering.
- **Offline fixture, packaging logic only.** Local package checks used the
  `windows-runtime-bundle` artifact of
  [run 35753297969](https://github.com/crmitchelmore/justspeaktoit/actions/runs/35753297969),
  downloaded read-only and matched to its documented ZIP SHA-256
  `2e92ec9c2e95ec891cc17ad22b79e6d5e00f88394d4dc01e50f64eb5cedf3316`. That run
  tested PR merge `386ddeb5`, whose tree equals `5aab9c5e`. It predates this
  branch's base `5e4169dc` and its later Windows source changes, so its
  executable is not this revision's. From it the builder produced the 35-file
  layout, the 30 bundle files unchanged, deterministically across runs; the
  wrong commit was refused, and an MSIX-shaped archive of the real layout
  passed the block-map verifier while tampered and mismatched copies failed.
  The logos were inspected visually. Runtime and package qualification of the
  integrated revision must come from fresh CI; this fixture is not a receipt
  for it.
- On macOS with PowerShell 7.6.6, a parse of the owned PowerShell sources found
  no errors, and each file is ASCII. The C# helper compiled with
  `-langversion:5` without invoking anything. `test-lifecycle-ownership.ps1`
  passed all 22 fake-machine checks with no failures. They include: a refused
  admission performs no process, package, certificate or file operation;
  cleanup removes only owned state; a foreign registration is kept and fails
  the run; and each kind of incomplete cleanup fails the run. Root
  independently reproduced the same 22 passes at `add035fe`.
- **Not yet executed:** the Windows PowerShell 5.1 run of the ownership test,
  MakeAppx packing, signing, the admission control and every Windows install,
  launch, failure, upgrade and uninstall step. They run only in the
  `package-lifecycle` job, which has not run for this revision. No
  installation receipt exists yet.

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
