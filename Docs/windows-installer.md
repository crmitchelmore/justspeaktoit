# Windows developer MSIX package

This is the Windows installer: **unsigned developer MSIX packages** for x64
and ARM64 built from the verified self-contained runtime bundles with
Microsoft's MakeAppx, one **multi-architecture `.msixbundle`**, lifecycle tests
that sign with ephemeral certificates on disposable CI runners and install,
launch, upgrade and uninstall them, **signing with a Certum Open Source
certificate** (Azure Artifact Signing as the alternative), and **App Installer
and winget files** for an update channel. It is not an Alpha or Stable
release, and nothing here publishes. The ARM64 package is built from the ARM64
bundle by `windows-arm64.yml` ([Windows ARM64](windows-arm64.md)). No install
receipt exists until the `package-lifecycle` and `package-bundle` jobs have
passed for a revision (see [Evidence](#evidence-at-this-checkpoint)).

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
| Execution alias | `JustSpeakToItDeveloper.exe`, and `speak.exe` for the automation CLI when the bundle carries it |
| Protocol | `justspeaktoit` (the Stable train's URL scheme, which the app parses), passing the link as the only argument |
| Architecture | The runtime bundle's: x64, or arm64 from the ARM64 bundle (`processorArchitectures` lists both) |
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
two lifecycle packages (uploading the `.2` package), `.3` for signed packages
and `.4` for the multi-architecture bundle. These numbers only order
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

Windows installs only signed packages through Add-AppxPackage or App Installer,
so every public build needs a publicly trusted code signing certificate whose
subject is the package Publisher. `signing_configuration.py` reads the signing
settings in the `sign` job and picks one of these routes; none of them puts a
key, certificate file or password in the repository:

- **Unsigned developer packages** (`windows-developer-msix-unsigned`,
  `windows-developer-msixbundle-unsigned`). Every CI run produces them. With no
  signing setting the `sign` job logs "Windows signing is not configured ...
  keeping the unsigned developer MSIX" and succeeds. The Windows 11
  unsigned-package route needs a special publisher OID that gives a different
  identity, so it is not used.
- **Certum in CI** (`WINDOWS_SIGNING_METHOD=certum`, the primary route). The
  job installs the pinned SimplySign Desktop, logs in with the account e-mail
  and a one-time password computed from the SimplySign seed, signs both
  packages and the bundle with the certificate's thumbprint through the pinned
  SignTool, timestamps at `http://time.certum.pl` (RFC 3161), reads each
  signature back and uploads `windows-developer-msix-signed`. The key stays in
  Certum's cloud HSM. See [Certum: the owner's steps](#certum-the-owners-steps).
- **Certum on your own PC** (`WINDOWS_SIGNING_METHOD=certum-local`). CI builds
  the unsigned packages and bundle with your certificate subject as Publisher
  (`windows-msix-for-local-signing`) and
  `sign-windows-package-locally.ps1` signs them where the certificate is
  available: a SimplySign Desktop session or the Certum card.
- **Azure Artifact Signing** (`WINDOWS_SIGNING_METHOD=azure`, alternative).
  Signs the x64 package through GitHub OIDC; see
  [Setting up Azure Artifact Signing](#setting-up-azure-artifact-signing). Not
  available to an individual outside the US and Canada.
- **Any certificate in a Windows certificate store.** Rebuild the layout with
  `--publisher "<certificate subject>"`, pack it, then run
  `sign-windows-package.ps1 -CertificateThumbprint <sha1> -TimestampUrl <RFC 3161 URL>`.
  The script checks that the subject equals the manifest publisher, the code
  signing EKU and validity, signs a copy with the pinned SignTool, reads the
  signature back and proves the payload and block map (or, for a bundle, every
  inner package) are unchanged. A self-signed certificate must be imported
  into each machine's Trusted People store and is suitable only for testing.
- **CI test certificates.** The lifecycle and bundle jobs create a
  NonExportable, three-hour self-signed certificate in the runner's user
  store, trust only its public part in `LocalMachine\TrustedPeople`, sign
  through the same script and remove certificate, key and trust before the job
  ends. Test-signed packages are not uploaded as signed builds.

The rules for the settings are the same for every method: none set keeps the
unsigned packages; a complete, valid set signs; a partial set, settings of two
methods at once or a malformed value fails the job and names the settings
(never their values).

A new publisher is a new package family, so choose the signing identity once:
changing it later means users uninstall and reinstall (or a
[persistent identity](https://learn.microsoft.com/windows/msix/package/persistent-identity)
migration). For Certum this includes the town and county in the subject: keep
them identical at every renewal.

### Choosing a signing route (September 2026)

| Route | Price | Who can use it | Notes |
|---|---|---|---|
| [Certum Open Source Code Signing](https://shop.certum.eu/code-signing.html) | Checked 27 September 2026 on shop.certum.eu: **EUR 49** a year in the SimplySign cloud (listed as out of stock that day), **EUR 69** for the set with a cryptoCertum card and reader, **EUR 25** for the certificate code alone (needs your own cryptoCertum 3.6 or 3.7 card). The shop shows the same net and gross figure; reviews quote the prices plus VAT. Card delivery to the UK was reported at about EUR 35 by DHL | Individuals who maintain an open-source project, worldwide, including the UK. Certum issues Open Source certificates to individuals only and states they must not be used for commercially distributed software | Subject `CN="Open Source Developer, <your name>", O=Open Source Developer, L=<town>, S=<county>, C=GB`. One-year validity; identity validation can be reused for at most 398 days, so expect to validate again each year. The cloud account allows 5,000 signatures a month. Key in Certum's HSM (cloud) or on the card |
| [Azure Artifact Signing](https://learn.microsoft.com/azure/artifact-signing/overview) (formerly Trusted Signing) | Basic $9.99/month (5,000 signatures, one profile of each type); Premium $99.99/month (100,000, ten); $0.005 per extra signature ([pricing](https://azure.microsoft.com/pricing/details/artifact-signing/)) | Public Trust: organisations in the US, Canada, EU, UK, Australia, New Zealand, Japan, South Korea, Singapore, Switzerland, Norway and Israel; individual developers in the US and Canada only ([prerequisites](https://learn.microsoft.com/azure/artifact-signing/quickstart#prerequisites)). Needs a paid (not free or trial) Azure subscription | Keys in FIPS 140-3 Level 3 HSMs, short-lived certificates renewed automatically, no token, GitHub OIDC. Subject is the validated legal name; no custom CN or O. Not EV |
| [Microsoft Store](https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options) (Partner Center) | Free registration for individuals and companies | Worldwide | The Store re-signs the MSIX after certification. Store distribution only: it does not sign a package you host yourself |
| Commercial OV certificate on a token or cloud HSM (for example SSL.com eSigner, DigiCert KeyLocker) | About $150 to $300 a year | Worldwide | Private keys must live on hardware (CA/Browser Forum, June 2023). Signs through `sign-windows-package.ps1` |
| EV certificate | $400+ a year | Worldwide | Since 2024 EV no longer bypasses SmartScreen reputation, so it offers nothing extra here |
| [SignPath Foundation](https://signpath.org/) | Free for qualifying open-source projects | OSI-licensed, released, actively maintained projects | Signs through SignPath's pipeline with the Foundation's certificate, so the publisher is SignPath Foundation rather than the project owner |

**Choice: Certum Open Source Code Signing, in the SimplySign cloud.** The owner
is a UK individual, so Azure Artifact Signing is not available. Certum's Open
Source certificate is the cheapest publicly trusted certificate issued to an
individual in the UK, names the owner as publisher, and in the cloud variant
keeps the key in Certum's HSM while still allowing CI to sign. If the cloud
variant stays out of stock, the card set works too, but a card cannot be used
from a hosted runner: sign on your own PC with `certum-local`.

**Is unattended CI signing realistic with Certum?** Partly, and it is not
verified here. Certum offers no signing API, command-line login or GitHub
Action. The only unattended route is the one community projects use (for
example [jay0lee/certum-cloud-code-sign](https://github.com/jay0lee/certum-cloud-code-sign)):
install SimplySign Desktop on the runner, compute the one-time password from
the seed in the pairing QR code, and type the login into its dialog. That is
what `connect-certum-simplysign.ps1` does, with a pinned MSI and a strict
subject check. It depends on SimplySign Desktop's dialog not changing, and the
seed plus e-mail let anyone sign as you until the seed is regenerated. Certum's
terms say nothing found here about automated logins. Treat the CI route as
convenient but fragile: if a login fails, the job fails rather than shipping
unsigned, and `certum-local` with `sign-windows-package-locally.ps1` is the
dependable fallback that needs no secret in GitHub at all.

SmartScreen may still warn on the first downloads of any newly signed build;
reputation builds as consecutive releases are signed with the same
certificate. A yearly Certum renewal is a new certificate, so reputation may
partly restart (not verified).

### Certum: the owner's steps

These need you in person; nothing in CI can do them.

1. **Buy the certificate.** Prefer the cloud variant:
   <https://shop.certum.eu/open-source-code-signing-on-simplysign.html>
   (EUR 49 on 27 September 2026, out of stock that day). The card set is
   <https://shop.certum.eu/open-source-code-signing.html> (EUR 69), and the
   code alone for an existing cryptoCertum card is
   <https://shop.certum.eu/open-source-code-signing-code.html> (EUR 25).
   Order as a private person with your legal name.
2. **Validate your identity.** Certum's list is at
   <https://support.certum.eu/en/code-signing-required-documents/>. Expect:
   - a photo ID (passport, national ID card, driving licence or residence
     card), checked by automatic video verification (recommended; a UK
     applicant in October 2025 used IDnow: both sides of a driving licence,
     then a short face video), or at a registration point, or by a notary;
   - a utility bill in your name as proof of address;
   - the public address of your open-source project, with your name visible
     on it (make your name visible on your GitHub profile and link
     <https://github.com/crmitchelmore/justspeaktoit>).
   Reported turnaround is two days to a week.
3. **Activate.** For the cloud variant, install the SimplySign mobile app,
   pair it by scanning the QR code Certum shows while activating, install
   [SimplySign Desktop](https://www.certum.eu/en/simplysign/) on a Windows PC,
   log in and check the certificate appears. For the card, install proCertum
   CardManager, insert the card and complete the certificate activation on it.
4. **Copy the exact subject.** On that PC, in PowerShell:

   ```powershell
   Get-ChildItem Cert:\CurrentUser\My |
     Where-Object { $_.Subject -like '*Open Source Developer*' } |
     Format-List Subject, Thumbprint, NotAfter
   ```

   The `Subject` line, character for character (it quotes the CN because the
   CN contains a comma), is `WINDOWS_MSIX_PUBLISHER`. Keep the thumbprint for
   `CERTUM_CERTIFICATE_THUMBPRINT`.
5. **Keep the one-time-password seed (cloud, CI signing only).** The pairing
   QR code encodes an `otpauth://totp/...` URI. To sign in CI you need that URI:
   decode the QR code when you pair (or re-pair) the phone, and store the URI
   only in the GitHub secret below. Anyone with it and your e-mail can sign as
   you; regenerate it in SimplySign if it leaks. Skip this step for
   `certum-local`.
6. **Create the GitHub environment.** Repository Settings > Environments >
   New environment `windows-signing`. Restrict deployment branches to `main`
   and add yourself as a required reviewer, so every signature waits for you.
7. **Add the settings** to that environment:

   | Kind | Name | Value | Needed for |
   |---|---|---|---|
   | Variable | `WINDOWS_SIGNING_METHOD` | `certum` or `certum-local` | both |
   | Variable | `WINDOWS_MSIX_PUBLISHER` | the subject from step 4 | both |
   | Variable | `CERTUM_CERTIFICATE_THUMBPRINT` | the thumbprint from step 4 (optional; pins the certificate) | both |
   | Secret | `CERTUM_SIMPLYSIGN_USERNAME` | the e-mail address of the SimplySign account | `certum` |
   | Secret | `CERTUM_SIMPLYSIGN_OTP_URI` | the `otpauth://totp/...` URI from step 5 | `certum` |

8. **Run it.** Actions > macOS to Windows Swift Proof > Run workflow on
   `main` (or push to `main`), then approve the `windows-signing` deployment.
   With `certum`, download `windows-developer-msix-signed`: signed x64 and
   ARM64 packages, the signed `.msixbundle`, `.sign.json` receipts and the
   update-channel preview. With `certum-local`, download
   `windows-msix-for-local-signing` and, on your PC with SimplySign logged in
   or the card inserted, run from a checkout:

   ```powershell
   ./scripts/windows-package/sign-windows-package-locally.ps1 -Artifact <download folder> -Output signed
   ```

   It finds the certificate whose subject equals the packages' Publisher (or
   `-CertificateThumbprint`), signs copies, timestamps at
   `http://time.certum.pl`, reads the signatures back and verifies the
   payloads. It uploads nothing.
9. **Renew yearly** with the same name, town and county, so the subject and
   the package family stay the same; update `CERTUM_CERTIFICATE_THUMBPRINT`
   if you set it.

If the Certum login fails in CI, the job log names the step; `Certificates
visible:` lists what SimplySign exposed. A subject mismatch means
`WINDOWS_MSIX_PUBLISHER` differs from the certificate subject. To stop
signing, delete `WINDOWS_SIGNING_METHOD` and the Certum settings: CI returns
to unsigned packages.

### Setting up Azure Artifact Signing

The alternative for an organisation, or an individual in the US or Canada. It
signs the x64 package only; set `WINDOWS_SIGNING_METHOD=azure` if Certum
settings also exist. Do these once, in this order. Only the portal can complete
identity validation.

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

## Links, the speak command and single-instance forwarding

- **`justspeaktoit://` links.** The manifest registers the Stable train's URL
  scheme (`application.protocol`) through `windows.protocol` activation with
  `Parameters="&quot;%1&quot;"`, so Windows starts `SpeakWindows.exe` with the
  link as its only argument. The vocabulary is the iPhone app's
  (`DeepLinkRouter`); the macOS app registers no URL scheme. Windows answers
  `justspeaktoit://` and `://open` or `://transcribe` (bring the window
  forward), `://start`, `://stop` and `://toggle` (and
  `://transcribe?action=start|stop|toggle`), which act like Record with no
  captured field, so the transcript is saved and offered for Copy, and
  `://cloudkit-sign-in?ckWebAuthToken=…`, the custom-scheme iCloud sign-in
  callback. `dictate`, `x-callback-url`, `openclaw` and the `destination`,
  `lang`, `model` and `maxDuration` options are refused with a reason in the
  status line. Browsers ask before opening an external protocol; a link can do
  only what the Record button does.
- **Single instance for links.** The first interactive window owns a named
  pipe, `\\.\pipe\JustSpeakToIt-SpeakApp-activation-<user SID>` (created with
  `FILE_FLAG_FIRST_PIPE_INSTANCE`, so owning it is the single-instance check;
  `SPEAK_ACTIVATION_PIPE` overrides the name). A later launch that carries a
  link finds the pipe in use, forwards the link and exits; the running window
  performs it and comes to the front. The pipe uses the automation pipe's
  native layer: only this user, on this computer, at no lower integrity than
  the app, so a sandboxed browser renderer cannot write to it. A plain launch
  while a window runs still opens a second window, as before; making every
  launch single-instance is a separate product decision. Links that arrive
  before the window is ready wait (at most eight).
- **`speak.exe` on PATH.** When the runtime bundle carries `speak.exe` (the
  cross-build and the ARM64 native build now produce and stage it, and the
  bundle builder authenticates it like the app), the manifest adds a second
  `windows.appExecutionAlias` for it, so `speak status`, `speak listen` and
  `speak mcp` work in any terminal once the package is installed. The CLI still
  needs Settings → Allow automation in the app. A bundle without `speak.exe`
  gets no such alias. The lifecycle and bundle jobs run `speak --version`
  through the alias.

## Multi-architecture bundle

`build-windows-release-packages.ps1` builds one `.msix` per runtime bundle at
a shared version and bundles them with the pinned MakeAppx into
`JustSpeakToIt-Developer_<version>_unsigned.msixbundle`
(`bundle-windows-packages.ps1`). `verify-windows-msixbundle.py` then proves
each inner package is its input byte for byte, that each architecture appears
once, and that the bundle and its packages share name, publisher and version.
Windows installs only the package matching the PC from a bundle.

The `package-bundle` job in `windows-cross-proof.yml` runs it for every
revision: it takes the x64 runtime bundle from this run and waits for the
ARM64 one from `windows-arm64.yml` for the same commit (the two workflows'
path filters name each other, and the job fails if the ARM64 run never
uploads its bundle). It installs a test-signed copy on the x64 runner and
requires the x64 package, its aliases and the protocol registration, then
uninstalls. It uploads `windows-developer-msixbundle-unsigned`. Once a
family moves to a bundle it cannot go back to single `.msix` files, so a
public channel should start with the bundle.

## Updates: App Installer and winget

`update_channel.py` writes, for a built bundle (or package):

- an **App Installer file** whose `Uri` is the channel's own feed location and
  whose `MainBundle` points at the immutable versioned release asset, with
  `OnLaunch` checks every 12 hours that never block launch, the
  `AutomaticBackgroundTask`, and no forced downgrade;
- for channels with a winget identity, a **winget manifest template**
  (version, installer and default-locale files for `winget-pkgs`, manifest
  schema 1.10.0) with one installer entry per architecture, the bundle's
  SHA-256 and, for a signed bundle, its `SignatureSha256`. It is never
  submitted.

The feed base comes from the `WINDOWS_UPDATE_FEED_BASE` variable and defaults
to GitHub Releases, `https://github.com/crmitchelmore/justspeaktoit/releases`.
`update-channels.json` defines three channels:

| Channel | Package | App Installer file lives at | State |
|---|---|---|---|
| developer | `com.justspeaktoit.windows.developer` | `<base>/download/windows-developer-<version>/JustSpeakToIt-Developer.appinstaller` | Built by CI; preview only, no release asset is ever created |
| alpha | `com.justspeaktoit.windows.alpha` | a mutable URL from `WINDOWS_ALPHA_APPINSTALLER_URL` (Alpha is never GitHub Latest, as the Mac Alpha appcast resolves the `alpha-latest` pointer) | Reserved, not commissioned |
| stable | `com.justspeaktoit.windows` | `<base>/latest/download/JustSpeakToIt.appinstaller`, which only the Stable GitHub Latest release answers | Reserved, not commissioned; winget `crmitchelmore.JustSpeakToIt` |

Every CI bundle carries a developer-channel preview in `update-channel/`.
Nothing uploads, tags, creates a release or submits to winget. To bring
Windows into the [release trains](alpha-stable-release-trains.md), the owner
must first add a Windows surface to `ReleaseTrains.json` and
`ReleasePipeline.json`, give the Alpha and Stable identities their own data
directories in the app (every Windows build uses `%LOCALAPPDATA%\JustSpeakToIt`
today), and add a Windows worker that takes a manifest tag like the Mac and
iOS workers. Alpha would then upload its bundle to the `alpha-build-N`
prerelease and move `WINDOWS_ALPHA_APPINSTALLER_URL`'s file; Stable would
upload only inside the owner's **Publish Stable** run, never on a merge, tag or
successful build. App Installer also needs a signed bundle whose publisher
never changes.

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
- MakeAppx `bundle` builds the `.msixbundle`; `verify-windows-msixbundle.py`
  independently requires each inner package to be its input byte for byte and
  the bundle manifest to describe exactly those packages under one identity.
  After signing, only `AppxSignature.p7x` and SignTool's catalogue may be added.
- SimplySign Desktop 9.4.4.92 (`SimplySignDesktop-9.4.4.92-64-bit-en.msi` from
  `files.certum.eu`, 273,982,464 bytes, SHA-256 `8ec420fc…4da3`, computed from
  the official download on 27 September 2026) is pinned in `dependencies.json`
  and must also carry a valid Authenticode signature. Only the Certum signing
  job installs it, on a disposable runner. `certum_signing.py` computes RFC 6238
  one-time passwords (checked against the RFC's SHA-1, SHA-256 and SHA-512
  vectors) from the `otpauth://` seed and never prints the seed.

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

- **Distribution slice, 27 September 2026 (local, before CI).** On macOS with
  Python 3.14.4: 64 packaging tests (identity, manifest protocol and aliases,
  companion executables, bundles, App Installer and winget files, Certum and
  Azure signing plans, one-time passwords), 85 bundle tests (two x64-only
  skips) and the other Windows tooling suites pass. PowerShell 7.6.6 parsed
  every packaging script with no errors, all ASCII. The Swift app, `speak.exe`
  and the complete test executable cross-compiled for Windows x64 from this
  Mac with the pinned toolchain. **Not executed here:** MakeAppx bundling,
  the bundle install, SimplySign login and Certum signing, and every Windows
  run of the new activation pipe; their receipts must come from CI (and, for
  Certum, from the owner's account).
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

- **Certum certificate (owner).** Purchase, identity validation and
  activation are the owner's steps above. Until then the `sign` job keeps the
  unsigned packages. The SimplySign login automation has never run against a
  real account; if it proves unreliable, use `certum-local`.
- **ARM64 signing receipt.** The `sign` job signs the ARM64 package and the
  bundle as well as x64 with Certum; Azure Artifact Signing still signs x64
  only.
- **Release identities and publication.** The Alpha and Stable Windows
  identities are reserved in `update-channels.json` but not commissioned. They
  need a Windows surface in the release-train manifest, train-specific data
  directories in the app (like Apple's `applicationSupportDirectory`; today
  every Windows build shares `JustSpeakToIt`) and a Windows release worker.
  Stable publication stays the owner's Publish Stable run.
- **Acceptance not covered by CI.** A clean physical Windows 10 and Windows 11
  machine without development tools; the App Installer double-click flow and
  its update check against a hosted feed (not present on the Server runner);
  a browser opening `justspeaktoit://` links and the CloudKit Console callback
  in each mode; SmartScreen and reputation for a signed build; the microphone
  consent prompt under the package identity; saving, using and removing a real
  credential across upgrade and uninstall; high-DPI logos with scale variants
  and a resource index; and the console window.
