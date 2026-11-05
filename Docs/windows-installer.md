# Windows installer and developer MSIX package

This page covers two packages:

- the **public beta installer**: one signed `.msixbundle` (x64 and ARM64)
  opened through an App Installer file, with automatic updates; and
- the **developer MSIX**, an unsigned per-architecture package used only for
  CI lifecycle checks. The rest of this page, from
  [Identity and version](#identity-and-version), describes it.

## Public beta installer

| URL | Purpose |
|---|---|
| <https://justspeaktoit.com/alpha/download/windows> | Website CTA. Redirects to the App Installer file once a signed installer is qualified; until then to the developer ZIP (`?arch=arm64` for ARM64, x64 otherwise) |
| <https://justspeaktoit.com/alpha/windows/JustSpeakToIt.appinstaller> | The App Installer file (`application/appinstaller`, served as a download). Windows' App Installer opens it, picks the package for the PC's architecture and rechecks the same URL for updates. 503 until a signed installer is qualified |
| <https://justspeaktoit.com/alpha/windows/installer.json> | `{available, channel, tag, build, version, publisher, appInstaller}` for the qualified installer, or `{available: false}` |

The file is a download rather than an `ms-appinstaller:` link because Microsoft
[disabled that protocol by default](https://learn.microsoft.com/windows/msix/app-installer/installing-windows10-apps-web)
in December 2023. Opening the downloaded `.appinstaller` shows the App
Installer dialog with the publisher name, then installs; no ZIP, Swift
runtime or SDK is involved, and Start, the execution aliases
`JustSpeakToIt.exe` and `JustSpeakToItCLI.exe`, and Settings > Apps uninstall
work as for any packaged app. Windows 10 2004 (10.0.19041) or later with App
Installer is required.

The website's Windows download action checks `installer.json` with a three-second
budget and offers **Install Windows beta** only when qualified, canonical
installer metadata is available. Otherwise it clearly offers the unsigned ZIP.
On Windows, browser architecture hints select the native ARM64 or x64 ZIP.
Browsers without those hints retain a labelled x64 fallback and explicit links
for both architectures; **Settings > System > About > System type** is the
manual authority. Installer-status failures leave the ZIP recovery path visible
with an explicit notice. The setup disclosure explains extraction, keeping DLLs
and resources together, separate model downloads, updates and data storage.
No JavaScript, signing-account enrolment or security-warning bypass is required
to follow the explicit ZIP instructions.

**Identity.** `scripts/windows-package/package-identity-beta.json` declares
package name `com.justspeaktoit.windows`, display name "Just Speak to It
(Beta)" and no default publisher: the publisher is always the signing
certificate's exact subject (`WINDOWS_MSIX_PUBLISHER`). It is a separate
package family from the developer MSIX and shares its data directory, so
History and settings carry over. The publisher becomes part of the package
family name, so **the first public publisher is permanent**: a later change
means users uninstall and reinstall.

**Version.** The release manifest's 12-digit build `YYYYMMDDhhmm` becomes
`YYYY.MMDD.hhmm.0` (for example `202610301641` gives `2026.1030.1641.0`), so
every later Alpha or Stable candidate is a newer package.

**Updates.** The App Installer file asks Windows to check on launch every 12
hours (with a prompt, not blocking launch) and in a background task. A newer
signed bundle under the same identity installs over the old one; Windows
refuses a lower version.

**Pipeline** (`.github/workflows/windows-installer.yml`, called by
`alpha-release.yml` for each Alpha after desktop qualification):

1. `sources` takes the release manifest's qualified x64 and ARM64 runtime
   bundles from `desktop-qualification.json`, checking each artifact still
   matches the published bytes.
2. `rehearse` (every change and every Alpha, on `windows-2022` and
   `windows-11-arm`) builds both beta packages and the bundle, signs it with an
   ephemeral non-exportable CI certificate trusted only for the job, and runs
   `test-windows-installer.ps1`: install through `Add-AppxPackage
   -AppInstallerFile`, exactly one registration at the expected version,
   native architecture, publisher and update URI, both aliases, then the newer
   file published at the update URI, Windows reporting that update for the
   installed package (`CheckUpdateAvailabilityAsync`), applying it, a refused
   downgrade, uninstall and removal of registration and aliases.
3. `sign` (environment `windows-signing`, `main` only) builds the same bundle
   with `WINDOWS_MSIX_PUBLISHER`, signs it with Azure Artifact Signing over
   GitHub OIDC, timestamps it, checks `signtool verify /pa`, the signer subject
   and the unchanged payload, and writes `<bundle>.sign.json`. Without the
   signing settings it logs that and stops: nothing is published.
4. `stage` uploads the signed bundle and the production `.appinstaller` to the
   manifest's release.
5. `verify` installs that published file on clean x64 and ARM64 runners with no
   imported trust (the certificate must chain to a public root). The live
   update URI still serves the previous release until promotion, so this job
   proves a clean install; step 2 proves the update path.
6. `promote` records `windows-installer.json` on the release and only then
   advances `windows-installer-pointer.json` on `alpha-latest` to a newer
   build. The website follows that pointer, which can lag the Alpha pointer.

Manual run: Actions > Windows installer > Run workflow, with a manifest tag to
publish (from `main`) or blank to rehearse the current Alpha.

**What signing does and does not give.** Keep these separate:

| Property | Provided by | Status |
|---|---|---|
| Windows will install the package at all | A signature chaining to a trusted root, publisher = manifest | Rehearsed in CI with a test certificate; public signature awaits the owner's choice of route |
| Publisher name shown in App Installer | Identity validation of the signing account | Owner action ([routes](#routes-for-a-uk-individual-november-2026)) |
| Signature valid after the certificate expires | RFC 3161 timestamp (`http://timestamp.acs.microsoft.com`) | Checked by the `sign` job |
| No SmartScreen "unrecognised app" prompt | Reputation earned by the signing identity over time and downloads | Not guaranteed. A trusted signature replaces "Unknown publisher" with the validated name; SmartScreen may still warn on early downloads of a new identity until consecutive releases signed with it build reputation |
| Store verification | Microsoft Store certification | Not used (direct download) |
| Malware scanning | Microsoft Defender at download/install | Normal OS behaviour |
| Clean-device install and update | `verify` on clean hosted runners | Per release, in CI; physical Windows 10/11 machines remain a manual check |

**Owner actions to publish.** Nothing ships until the owner, not an agent,
chooses and enrols in a signing route. The publisher is an individual in the
UK, so Azure Artifact Signing (individuals: US and Canada only) is not
available; see [Routes for a UK individual](#routes-for-a-uk-individual-november-2026)
for the options, costs and enrolment steps. The pipeline below is wired for
Artifact Signing and rehearsed with a job-only test certificate; it does not
switch provider until a route is chosen.

## Identity and version

`scripts/windows-package/package-identity.json` is the only Windows package
identity in the repository.

| Field | Value |
|---|---|
| Package name | `com.justspeaktoit.windows.developer` |
| Default publisher | `CN=Just Speak to It Developer` (placeholder for the unsigned package) |
| Package family | `com.justspeaktoit.windows.developer_12qtdfzdxrxs0` for the default publisher |
| Application / AUMID | `JustSpeakToIt` / `<family>!JustSpeakToIt` |
| Hidden CLI application / AUMID | `JustSpeakToItCLI` / `<family>!JustSpeakToItCLI` |
| Display name | Just Speak to It Developer |
| GUI execution alias | `JustSpeakToItDeveloper.exe` → `SpeakWindows.exe` (unchanged) |
| CLI execution alias | `JustSpeakToItDeveloperCLI.exe` → `speak.exe` (console) |
| Architecture | The runtime bundle's: x64, or arm64 from the ARM64 bundle (`processorArchitectures` lists both) |
| Target | `Windows.Desktop`, minimum 10.0.19041.0, tested 10.0.20348.0 (the CI runner build) |
| Capabilities | `runFullTrust`, `unvirtualizedResources` (restricted), `microphone` (device) |
| Payload | Every file of the verified runtime bundle, byte for byte (including its `README.txt`, which describes the portable bundle), plus `AppxManifest.xml`, canonical logos and scale/target-size variants, and `package-manifest.json` |

The family name is Windows' hash of the publisher. The builder computes it
(checked against Microsoft's published `8wekyb3d8bbwe` and `cw5n1h2txyewy`
IDs) and the lifecycle test requires Windows to report the same value.

The package carries the real `speak` SwiftPM release product for both x64 and
ARM64, using the verified bundle's two executable hashes and exact multi-root
dependency graph. Packaging re-reads both PEs and their static/delay imports;
missing/tampered CLI bytes, test or unknown imports, foreign architecture and
false importer/root attribution are refused before layout creation.

The SDK permits only one `windows.appExecutionAlias` extension per Application,
even when the extensions use different namespace versions. The CLI therefore
has its own `JustSpeakToItCLI` Application, with required canonical visual
assets and [`AppListEntry="none"`](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-uap-visualelements).
There are exactly two reviewed Applications but only one visible Start entry;
the GUI Application, AUMID, icons, alias and startup task remain unchanged.
The real CLI keeps
[`uap5:Extension`'s `Executable` override](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-uap5-extension)
and [`uap5:AppExecutionAlias`'s `uap10:Subsystem="console"`](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-uap5-appexecutionalias).
A console-subsystem alias must also declare
[`uap10:SupportsMultipleInstances="true"`](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-f-application)
on its own `Application` element; the hidden CLI Application does this and the
GUI Application is unchanged. No generic `speak.exe` alias is registered and no PATH, trust, install or
startup policy changes. Run `JustSpeakToItDeveloperCLI.exe --help` or
`JustSpeakToItDeveloperCLI.exe --version` after a developer package installation;
portable use remains `.\speak.exe`.
The existing Windows CLI version fallback is `0.0.0-dev`; it is not the MSIX
version. Other commands still use the running app's existing automation pipe.

Disposable-runner lifecycle checks require both aliases to appear and disappear,
verify the hidden CLI application and installed executable/alias association,
require exactly one visible GUI entry for the package family, and run help/version with
bounded redirected streams and isolated PATH. A pre-existing CLI alias or CLI
process blocks admission and is never owned or removed by a refused run.
Fast CLI checks do not substitute stdout for GUI module provenance. Fresh native
build and MakeAppx/install/alias/removal receipts are still required: earlier
GUI-only receipts do not qualify this CLI packaging change. The `6d920e46`
developer layouts were rejected by MakeAppx with `0x80080204` because both alias
extensions occupied the GUI Application. Static/mock topology tests alone do not qualify the corrected layout.
Actual x64/ARM64 SDK packing and installed alias/start/upgrade/removal passed
at the [current checkpoint](#evidence-at-this-checkpoint).

Package logos come from the canonical Mac 1024px export with transparent
corners. The three manifest roots (`StoreLogo`, `Square44x44Logo` and
`Square150x150Logo`) include high-DPI scale variants up to 400%; the 44px logo
also has unplated and light-unplated target-size variants for Start/search and
the taskbar. Both shell appearances retain the same coloured brand, rather
than treating the full application icon as a symbolic glyph. Windows resolves
these qualified siblings through MRT without extra manifest entries. The
executable's embedded native icon travels unchanged in the verified bundle
and package. Asset/package tests cover exact sizes, alpha and layout membership;
installed rendering and resource linkage still need the native lifecycle and
window checks. No new signed Stable distribution is implied.

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

`SpeakWindows.exe` links with the windows subsystem (`/SUBSYSTEM:WINDOWS`,
entry `mainCRTStartup`, in `Package.swift`), so Start menu, startup and
shortcut launches open no console window; `stage-native-app.py` refuses a
console-subsystem build. Diagnostic flags such as `--self-test` write to
redirected handles as before; run from a terminal without redirection, the app
attaches to that terminal's console, but the shell does not wait, so use
`Start-Process -Wait -NoNewWindow` or pipe the output. `speak.exe` stays a
console program.

## Signing

- **Unsigned developer package** (`windows-developer-msix-unsigned`). Windows
  installs only signed packages through Add-AppxPackage or App Installer. The
  Windows 11 unsigned-package route needs a special publisher OID that gives a
  different identity, so it is not used. Every CI run still produces it.
- **Signing provider in CI.** `WINDOWS_SIGNING_PROVIDER` chooses
  `artifact-signing` (the default when unset; see
  [Setting up Azure Artifact Signing](#setting-up-azure-artifact-signing)) or
  `sslcom-esigner` (see
  [Owner steps: SSL.com IV + eSigner](#owner-steps-sslcom-iv--esigner-direct-download)).
  The installer `sign` job supports both; the developer-package job
  (`windows-developer-msix-signed`) signs with Artifact Signing only and skips
  other providers. With no settings the jobs log "Windows signing is not
  configured ... publishing nothing" and succeed; a partial setup, settings
  for two providers without a choice, or a malformed value fails and names
  the settings, never their values.
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
| [Microsoft Store](https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options) (Partner Center) | Free for individual developers ([new flow](https://learn.microsoft.com/windows/apps/publish/whats-new-individual-developer), government ID and selfie) | Individuals in nearly 200 markets, including the UK | The Store re-signs the MSIX after certification. Store distribution only: it does not sign a package you host yourself |
| Individual (IV) or OV certificate on a token or cloud HSM (for example [Certum](https://shop.certum.eu/open-source-code-signing-on-simplysign.html) Open Source Code Signing in the Cloud, [SSL.com IV](https://www.ssl.com/products/software-integrity/code-signing/iv/) with eSigner, DigiCert KeyLocker) | Certum Open Source in the Cloud EUR 49 a year; SSL.com IV $129 a year plus [eSigner](https://www.ssl.com/guide/esigner-pricing-for-code-signing/) from $20 a month (20 signings) or $180 a year (240) | Worldwide individuals. Certum's Open Source certificate is for open-source maintainers; GlobalSign no longer issues to individuals | Private keys must live on hardware (CA/Browser Forum, June 2023). Certum's SimplySign needs a phone-app code per session and has no vendor-supported CI flow; SSL.com documents headless GitHub Actions signing with a TOTP secret |
| EV certificate | $400+ a year | Organisations only | Since 2024 EV no longer bypasses SmartScreen reputation, so it offers nothing extra here |
| [SignPath Foundation](https://signpath.org/terms) | Free for qualifying open-source projects | OSI-licensed (MIT qualifies), released, actively maintained, no proprietary components; any country | Signs MSIX and MSIX bundles ([formats](https://docs.signpath.io/artifact-configuration/reference)) in SignPath's HSM with the Foundation's certificate, so the publisher is SignPath Foundation rather than the project owner. Needs a "Code signing policy" page, named approvers, MFA, and per-release approval |

**Artifact Signing** is the cheapest publicly trusted route for an
organisation in one of the listed countries or an individual in the US or
Canada (about $120 a year, no stored secret, GitHub OIDC). It is not
available to this project's publisher, an individual in the UK.

### Routes for a UK individual (November 2026)

Each route below is open to a UK individual without forming a company.
Whichever route ships first fixes the package family: the MSIX `Publisher`
must equal the signing subject, so moving later between a personal
certificate, SignPath Foundation and the Store changes the identity and
existing installs do not upgrade across it.

| | Microsoft Store | SignPath Foundation | SSL.com IV + eSigner | Certum Open Source (cloud) |
|---|---|---|---|---|
| Cost | Free | Free | $129/yr certificate + eSigner $180/yr (240 signings) or more | EUR 49/yr |
| Name users see | Publisher display name set in Partner Center | "SignPath Foundation" | Owner's verified legal name | "Open Source Developer" + owner's legal name |
| Key custody | Microsoft re-signs; no key held | SignPath HSM; no key held | SSL.com cloud HSM; TOTP secret in a GitHub environment can sign | Certum cloud HSM; phone-app code per session |
| Unattended CI | Yes (Partner Center submission API) | Yes (GitHub Actions connector), with a human approval per release | Yes, documented GitHub Action; MSIX through SignTool needs a pilot | No vendor-supported route |
| Install and update | Store install, Store updates | Website `.appinstaller`, as built | Website `.appinstaller`, as built | Website `.appinstaller`, signed by hand on a Windows PC |
| SmartScreen | Store installs are not download-gated | Shared Foundation identity | New identity; builds reputation | New identity; builds reputation |

Every signing in each release counts: the pipeline signs each architecture's
package and the bundle (three signatures), so an eSigner tier must cover
every Alpha that is published, not only Stable.

**Recommendation: the Microsoft Store.** It is the simplest route that is
actually open to a UK individual: free, no certificate or key to custody, no
legal name inside a certificate, installs without the "unknown publisher"
and SmartScreen download prompts, and Windows updates it. The existing MSIX
bundle is reused; only its identity changes to the values Partner Center
reserves, and the Store, not `sign`, signs it. The website CTA would link to
the Store listing; the description keeps the beta label.

If the owner also wants a direct website download, add **SignPath
Foundation** when showing "SignPath Foundation" as publisher is acceptable
(free, no personal name), otherwise **SSL.com IV + eSigner** (own legal name,
about $310 a year, after a one-off MSIX pilot). Certum is cheapest but would
make every release depend on the owner signing by hand.

SmartScreen may still warn on the first downloads of any newly signed direct
build; reputation builds as consecutive releases are signed with the same
identity.

#### Owner steps: Microsoft Store

Done by the owner only; each step creates an account or accepts terms.

1. Go to <https://storedeveloper.microsoft.com>, choose **Get started for
   free** > **Individual developer**, sign in with a Microsoft account with
   MFA, and complete ID and selfie verification. Review the pre-filled
   profile and choose the publisher display name users will see.
2. In Partner Center > Apps and games, **reserve the name** "Just Speak to
   It". From Product identity copy `Package/Identity/Name`,
   `Package/Identity/Publisher` and `PublisherDisplayName`.
3. Tell the maintainers those three values. They are not secrets. An agent
   then builds the bundle with that identity and the `runFullTrust`
   justification and adds an upload job.
4. Provide a privacy policy URL and age rating, upload the first package by
   hand, and submit for certification.
5. Only if automated submission is wanted later: register an Entra ID app for
   the Partner Center submission API and store its credentials in a
   `main`-only environment.

#### Owner steps: SignPath Foundation (direct download)

1. Add a "Code signing policy" page to the website listing approvers and the
   privacy statement required by [the terms](https://signpath.org/terms).
2. Apply for the free OSS subscription at <https://signpath.org>, linking the
   repository, and accept SignPath's terms. Enable MFA on SignPath and
   GitHub.
3. After approval, install the SignPath GitHub App on the repository and
   share the organisation, project and signing policy slugs. An agent then
   adds a `signpath` provider to `sign`; each release waits for an approver.

#### Owner steps: SSL.com IV + eSigner (direct download)

1. Order an IV code signing certificate at
   <https://www.ssl.com/products/software-integrity/code-signing/iv/>,
   choosing eSigner cloud delivery, and pay.
2. Complete identity validation (government ID and liveness check).
3. Enrol the certificate in eSigner, choose a subscription tier, and set
   automated signing to get a TOTP secret.
4. On a Windows PC, install eSigner CKA once, load the certificate and copy
   its SHA-1 thumbprint and exact subject from `certmgr.msc` (Personal >
   Certificates). Neither is secret.
5. In the `main`-only `windows-signing` environment set:

    | Kind | Name | Value |
    |---|---|---|
    | Variable | `WINDOWS_SIGNING_PROVIDER` | `sslcom-esigner` |
    | Secret | `SSLCOM_ESIGNER_USERNAME` | eSigner account username |
    | Secret | `SSLCOM_ESIGNER_PASSWORD` | eSigner account password |
    | Secret | `SSLCOM_ESIGNER_TOTP_SECRET` | Base32 automated-signing TOTP secret from step 3 |
    | Variable | `SSLCOM_ESIGNER_CERTIFICATE_THUMBPRINT` | 40-hex SHA-1 thumbprint from step 4 |
    | Variable | `WINDOWS_MSIX_PUBLISHER` | Certificate subject from step 4, character for character |

6. Dispatch `Windows installer` on `main` with an existing Alpha manifest and
   check the `sign` job before relying on it. That job installs SSL.com's
   eSigner CKA (pinned by SHA-256 in `dependencies.json`), loads the
   certificate by thumbprint through
   `scripts/windows-package/load-sslcom-esigner.ps1`, signs the bundle with
   `/tr http://ts.ssl.com`, verifies it against the runner's trust and the
   timestamp, then the clean-runner install and promotion gates run as for
   Artifact Signing. This path is unit-tested but has not signed a real
   package yet: the first manifest run is the pilot.

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
   audio sample or other user file. It also requires the app's legacy setup
   migration to create `onboarding.json` with the canonical completed state.
   Missing, malformed or incomplete setup state and every other unexpected
   metadata file still fail the preservation check.
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

MakeAppx failures print the last 4096 characters of each captured output stream
and the full log path without changing the failure status. Separate always-run
pack-diagnostic artifacts retain only `*.pack.log` from the base, upgrade and
optional signed-job layouts, even when packing fails before lifecycle testing.
They do not include signing material or environment dumps.

## Evidence at this checkpoint

The current merged source is `ec1f53159c61b023f9dba5152e359a44fb6a9fdb`
([PR #1238](https://github.com/crmitchelmore/justspeaktoit/pull/1238)); its tree
matches tested `a6b5b53912af4e6024d0d65542df8dd0786005fc`. On 25 October 2026,
[x64 lifecycle](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40190710023)
and [native ARM64 lifecycle](https://github.com/crmitchelmore/justspeaktoit/actions/runs/40190709985)
passed actual SDK packing, install, GUI/CLI launch and alias checks,
failed-upgrade refusal, upgrade and removal. This qualifies the corrected
two-Application layout described above. Standalone bundles also ran without
installed Swift. Earlier pending receipt statements refer to those historical
checkpoints. Public Azure Artifact Signing was skipped; these results do not
establish public trust, physical-machine acceptance, updates or a Stable release.


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
- **Historical gap, now qualified:** the initial checkpoint had not executed
  Windows PowerShell 5.1 ownership checks, MakeAppx, test signing or the
  install/upgrade/removal lifecycle. Both architectures now have the passing
  current-checkpoint receipts above; public signing remains unqualified.

## Remaining gates and integration needs

- **ARM64.** `windows-arm64.yml` packs the ARM64 bundle as
  `ProcessorArchitecture="arm64"` in the same family and runs this lifecycle,
  unchanged, on `windows-11-arm`, where the pinned x64 MakeAppx and SignTool
  run under emulation. The ARM64 app and its lifecycle passed at the current
  checkpoint; no `.msixbundle` holds both architectures (a family may move
  from `.msix` to a bundle, not back). See
  [Windows ARM64](windows-arm64.md).
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
  logos with scale variants and a resource index; and a visual check that a
  Start menu launch opens no console window.
