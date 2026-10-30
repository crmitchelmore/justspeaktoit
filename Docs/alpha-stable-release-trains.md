# Alpha and Stable release trains

Alpha and Stable have separate app identities, data, Keychain services, iCloud
containers, URL schemes, transport discovery, update feeds and CLI destinations.
`Sources/SpeakCore/Resources/ReleaseTrains.json` is canonical; regenerate Swift
with `python3 scripts/generate-release-train-config.py` after changing it.

## Commissioning state

The previous automatic Stable publisher is disabled. Automatic Alpha allocation
is enabled in `Config/ReleasePipeline.json`, authorised by Chris on 11 September
2026. Successful main CI runs now enter the Alpha delivery pipeline; hourly
reconciliation retries successful merges accumulated since the Alpha controller
was introduced. Existing Stable downloads remain available.

Activation does not establish successful distribution. Signed archive, device,
public TestFlight and Alpha N-to-N+1 Sparkle verification remain delivery
acceptance checks and must be recorded from actual release evidence.

Apple Alpha records: iOS `6810300888`, macOS `6810302118`. Both have an external
Public Alpha group. TestFlight distribution is Alpha-only; Stable candidates
are processed for App Store submission without beta-group assignment. Existing
tester membership is preserved. Public
Alpha links live in the README only; the website and Homebrew advertise Stable.

Before a new Alpha beta-review submission, the worker enables Apple's per-build
[automatic tester notification](https://developer.apple.com/documentation/appstoreconnectapi/buildbetadetailupdaterequest/data-data.dictionary/attributes-data.dictionary)
and verifies readback. It does not change already-approved historical builds or
send manual notifications. Group assignment and notification configuration alone
do not establish availability; the receipt retains Apple's observed beta state.

### Local Apple release credentials from 1Password

`scripts/release-apple.rb` and `scripts/reconcile-apple-releases.rb` can explicitly
read their App Store Connect credentials from 1Password. Install the 1Password
CLI and authenticate with a service account or desktop-app integration. Supply
the service account's `OP_SERVICE_ACCOUNT_TOKEN` from the host's credential store;
service-account authentication does not require desktop unlock or `op signin`.
For desktop-app integration, unlock the app and authorise CLI access yourself
before running either script. Each read has a 30-second deadline with bounded
cleanup; unavailable vault access fails the command rather than waiting
indefinitely. See the official [service-account setup](https://developer.1password.com/docs/service-accounts/use-with-1password-cli/),
[CLI setup](https://developer.1password.com/docs/cli/get-started/) and
[`op read` reference](https://developer.1password.com/docs/cli/reference/commands/read/).

Configure references to existing fields, rather than credential values. These
example names are placeholders; use **Copy Secret Reference** in your vault:

```bash
export APP_STORE_CONNECT_CREDENTIAL_SOURCE=1password
export APP_STORE_CONNECT_KEY_ID_REF='op://Release/Apple/key-id'
export APP_STORE_CONNECT_ISSUER_ID_REF='op://Release/Apple/issuer-id'
export APP_STORE_CONNECT_PRIVATE_KEY_REF='op://Release/Apple/private-key'
```

The key-ID field must contain its 10-character uppercase ASCII alphanumeric ID;
the issuer field must contain its UUID. The private-key field must contain the
complete unencrypted PEM for a private P-256 key. Password-protected PEM is
rejected with an explicit empty passphrase; vault mode never asks for one
interactively. These correspond to Apple's
[team-key JWT header and claims](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests).
The scripts capture at most 64 KiB of `op read --no-newline` output in memory,
discard diagnostics with a separate 64 KiB limit, and validate the key. They
never print credential values, references or CLI error output or write a
temporary key file. Overflow and deadline failures signal only the owned CLI
process, with up to 250 ms each for TERM and KILL cleanup. If kernel I/O still
prevents exit, ownership transfers to an eventual reaper so the caller can fail
without another signal to that PID. Cancellation cannot preempt kernel work.
Redacted error categories distinguish reference configuration,
unavailable access, deadlines, output limits and invalid values/keys.
Any selected-vault failure stops authentication; it never
falls back to environment credential values or a local `.p8` file. Do not add
shell tracing or print the captured values.

When `APP_STORE_CONNECT_CREDENTIAL_SOURCE` is unset (or `environment`), the
existing CI/local contract remains: `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID` and `APP_STORE_CONNECT_KEY_PATH`, including the
existing default key ID/path. Provisioning/bootstrap entrypoints are unchanged.
This option does not change runner authentication, create vault items, submit a
build, or establish live vault/API access; those require separate verification.

## Alpha

Every successful main push CI allocates an immutable annotated
`alpha-build-N` tag containing a manifest. Independent workers build direct Mac
and iOS from that exact source. Allocation is idempotent; manual
`rebuild` creates a new build number for an expired or invalid Apple upload.
Hourly reconciliation retries missing deliveries, dispatching at most three
sources per pass and checking every page of active runs to avoid duplicate
in-flight deliveries. Remaining sources stay in the successful-CI ledger. Apple processing and beta
review are recorded as pending, never as successful shipment.

Direct Mac releases are GitHub prereleases. A single `alpha-latest` JSON pointer
routes Alpha feeds/downloads to immutable assets. It cannot change GitHub Latest,
Stable Sparkle feeds or Homebrew. Late older builds cannot roll back the pointer.

Each direct Mac worker re-runs the release-configuration tests on the pristine
tagged source *before* the manifest stamps train identity, version and release
notes into the tree; those stamps are what the plist-identity and release-notes
tests pin, so testing afterwards fails every build. Until the pointer exists,
`https://justspeaktoit.com/alpha/appcast.xml` answers 503 and an installed Alpha
reports "An error occurred in retrieving update information". Hourly
reconciliation dispatches with the workflow token (`actions: write`), not a
personal token.

The local Codex Run action launches Alpha with `script/build_and_run.sh`.
Alpha starts without a global recording hotkey; configure one in Settings.

### Direct Mac launch failures

Archive/export success is not launch acceptance. Both pre-notarisation and
post-notarisation launch gates must keep their candidate child alive. An early
exit (including the initial two-second check) records the exact PID and exit
status, content-free output/log accounting and structured crash evidence.
Crash-report delivery is polled for up to ten seconds;
system-log collection has its own five-second timeout. Missing diagnostics do
not turn a failed launch into a pass.

The direct Mac workflow preserves this evidence even when packaging fails, as
`mac-launch-diagnostics-<manifest>-<attempt>` (seven-day retention), separated by
architecture and launch phase. It uploads only collected launch evidence, not
signing environment, profiles, keychains or export logs. Locally, run
`VERIFY_LAUNCH_DIAGNOSTICS_DIR="$PWD/.artifacts/launch" scripts/verify-launch.sh /path/to/candidate.app`
to retain the same evidence without replacing an installed app. Each crash
report read is limited to 1 MiB. Discovery examines at most 256 directory entries
per polling pass, selects at most eight recent candidates before reading, and
reads at most eight report revisions in total. At most three structured reports
are retained; scan truncation, invalid/oversized reports and attribution rejection
are recorded as counters, without echoing untrusted filenames or parse errors.

Candidate stdout/stderr flows through an owned FIFO into a streaming discard
reader; unified logs flow through a subprocess pipe with a five-second timeout.
Each read is at most 32 KiB. No raw stream is spooled to disk, retained or echoed:
only generated numeric byte counts, timeout/availability and exit status are
saved. Slow or sustained producers cannot grow diagnostic temporary files.
The FIFO reader has a separate bounded termination path and never replaces the
candidate PID used by the launch gate.

Crash projections retain only known exception types, numeric exception codes,
frame offsets and image UUIDs/allowlisted image names for offline symbolication.
Free-form symbols, messages, environment, paths and arbitrary report text are
not uploaded. Modern reports must match the executable path, PID and launch
timestamp, and have a capture timestamp within the observed launch interval;
legacy reports must match path/PID and a crash timestamp within that interval.
For Apple's `/Users/USER/*/` path redaction, the complete app/executable suffix,
process name and the bundle identifier recorded before launch must also match.
The log query uses the recorded launch interval and executable path as well as
PID, rather than a sliding post-exit window. Reports with missing identity
fields are rejected explicitly. These checks reduce PID-reuse misattribution;
they do not assert that a numeric PID is an enduring process identity.

This is defense in depth against accidentally emitted signing/key data, not a
sandbox or protection from malicious repository code: the trusted release
candidate already runs with the workflow's authority. Raw stdout, unified logs
and crash-report text are intentionally unavailable in artifacts. A segfault
alone does not establish its root cause; retained UUIDs/offsets can be matched
to the exact build's binaries/dSYMs without persisting arbitrary candidate text.

Keep the `AnyView` boundary around normal launch content inside `SpeakApp`'s
scene. Without it, an isolated Release Alpha candidate from the `alpha-build-23`
app source crashed while SwiftUI's `AppGraph` resolved scene-associated-type
metadata: its expanded view tree reached `PaidAccessManager` and
`Published<String?>` metadata, then dereferenced a null pointer in the Swift
runtime. The boundary leaves the content, service bootstrap, onboarding and
paid-access feature gate unchanged while preventing that eager scene metadata
expansion. `SpeakAppSceneMetadataTests` exercises the associated-type witness
without starting app services. Local ad-hoc launch acceptance does not replace
the signed archive/export and notarisation gates on the release runner.

## Retired Mac App Store surface

The Mac App Store surface (`mac-store`) is retired from both trains. Its App
Sandbox breaks core dictation features (global hotkeys, accessibility text
insertion), and its Public Alpha TestFlight group never reached
`IN_BETA_TESTING`, so no Alpha could satisfy the Stable gate. Release manifests
now freeze only `mac-direct` and `ios`. Historical manifests and their
`mac-store-receipt.json` assets are kept as evidence but ignored by allocation,
reconciliation, Prepare Stable and Publish Stable. Stable workers run the selected
Alpha's exact source, so when that Alpha still froze `mac-store`, Prepare Stable
copies a deterministic `mac-store` entry marked `retired` (sharing the direct
Mac baseline) so the older validator can parse the candidate. That entry is
never dispatched, receipted or published. The existing App Store
listing and its users are not changed by this pipeline; delisting is a separate
owner action in App Store Connect.

## Stable

1. Select a delivered and tested `alpha-build-N` and explicit Mac/iOS versions.
2. Run **Prepare Stable**. It freezes source, dependency lock, per-surface
   publication baseline, versions, builds and exact release-note hashes in a
   `stable-candidate-N` manifest. It rebuilds using Stable identities.
3. Validate candidate downloads, Stable archive identity and runtime. Apple
   candidates must finish processing, but are not distributed through TestFlight.
   Review cumulative notes in the draft release. Alpha continues independently.
4. The repository owner runs **Publish Stable**, supplying the candidate and
   exact reviewed manifest SHA-256. This is the publication approval.
5. Direct Mac publishes verified candidate assets and updates Homebrew. It
   requires its own verified receipt and desktop qualification, not the Apple
   candidates. Each Apple surface is submitted with `AFTER_APPROVAL` only when its
   own candidate receipt verified; an unverified Apple candidate is skipped and
   keeps its previous Stable. Publication receipts advance Apple note baselines
   only after the exact build is publicly available.

Each surface has its own published baseline. TestFlight delivery, an upload, a
review submission and a rejected version do not advance it. Initial Apple Store
releases therefore include the full initial history. Paired reverts cancel only
within the unpublished range. Candidate receipt hashes guard source, build and
notes; direct assets are checked against recorded SHA-256 before promotion.

## Required rollout evidence

To complete distribution verification, verify Alpha profiles contain only Alpha groups and
cloud containers; deploy the matching CloudKit schemas; build signed archives on
all three surfaces; install Alpha alongside Stable on target devices; verify data
and permission isolation; exercise direct Mac Alpha N to N+1 updates; and confirm
public TestFlight availability. Store beta links without an available approved
build are setup evidence only.

Record observations in the existing [JSTI release tracker](https://app.notion.com/p/3d6ef116369981b98927fd8cddb95fa1).
Each observation must identify the immutable Alpha tag, source SHA, surface,
version/build, device where relevant, timestamp and release/workflow evidence.
For Sparkle, record both the starting and installed Alpha builds. Keep upload,
processing, beta review, public availability and device validation distinct.

Once enabled, repository users authorised to dispatch Actions can retry a
successful main Alpha source or request a rebuild. Owner-only dispatch while
disabled is the commissioning exception; Stable publication remains owner-only.

Required Alpha signing secrets are selected in the reusable Apple workflows.
No signing material belongs in source control. Use the existing secure API key
and local Apple Developer authentication for provisioning.

## Windows and Linux release qualification

New Alpha and Stable candidate manifests carry `desktopQualification: 1`.
Both controllers run `qualify-desktop-release.yml`, which dispatches the existing
Windows x64, Windows ARM64, Mac-to-Windows bundle/MSIX, Linux GTK and Linux
Flatpak workflows at the immutable manifest tag. This preserves their native
execution, packaging and installed-runtime checks. Each run checks out the same
source as the Apple builds, including its pinned runtime dependencies.

The controller records exact workflow run IDs, source, tag and build in
`desktop-qualification.json` only after every workflow succeeds. Publish Stable
requires that matching receipt for new manifests. Existing frozen manifests are
unchanged. Before writing the receipt, the controller copies the qualifying
runs' Windows x64 and ARM64 runtime bundles and the Linux x86_64 Flatpak onto
the manifest release as `JustSpeakToIt-windows-x64-developer.zip`,
`JustSpeakToIt-windows-arm64-developer.zip` and
`JustSpeakToIt-linux-x86_64.flatpak`, after checking each file's SHA-256 and
source commit against that run's own bundle evidence or Flatpak provenance.
The receipt records each download's run, architecture, size and digest. Workflow
artifacts expire after 14 days, so a reusable main run whose bundle has expired
is dispatched again rather than reused. `node scripts/publish-desktop-downloads.mjs <tag>`
backfills an already verified release from its receipt's runs. The website's
`/alpha/download/windows-x64`, `/alpha/download/windows-arm64` and
`/alpha/download/linux-x86_64` follow the Alpha pointer and answer 503 when that
Alpha has no published desktop download. These remain unsigned developer
builds; qualification does not publish installers or establish signing,
physical-device acceptance, update channels, feature parity or separate
Alpha/Stable Windows and Linux identities.
No separate public Windows/Linux version inputs are introduced yet: the
immutable manifest tag and build identify the developer qualification source.
Public platform versions and download links belong with those distribution
contracts, rather than being inferred from Apple's marketing versions.

If Prepare Stable reports an unverified Apple Alpha receipt, run **Reconcile
Apple release delivery** and inspect the updated receipt. `BETA_APPROVED` alone
is not the `IN_BETA_TESTING` or `READY_FOR_BETA_TESTING` state required by the
existing public-beta gate. Retry Prepare Stable after verification; do not edit
the receipt or bypass the gate. A new Alpha/Stable workflow definition takes
effect after merge; it does not modify a candidate already being prepared.

Desktop qualification reuses completed successful same-repository main-push
runs only when the source SHA and workflow path match exactly. A newer failed
run prevents reuse. Other sources, PR merge refs and fork runs never qualify a
release. Missing evidence dispatches the immutable release tag. Hourly Alpha
reconciliation includes the desktop receipt in its completion check, so missing
or invalid qualification stays eligible for recovery.
