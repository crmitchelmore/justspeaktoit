# Alpha and Stable release trains

Alpha and Stable have separate app identities, data, Keychain services, iCloud
containers, URL schemes, transport discovery, update feeds and CLI destinations.
`Sources/SpeakCore/Resources/ReleaseTrains.json` is canonical; regenerate Swift
with `python3 scripts/generate-release-train-config.py` after changing it.

## Commissioning state

The previous automatic Stable publisher is disabled. `Config/ReleasePipeline.json`
keeps automatic Alpha allocation disabled until provisioning and archive/device
verification are complete. This is an explicit commissioning gate, not a working
production release claim. Existing Stable downloads remain available.
The repository owner may manually dispatch a successful main SHA while this gate
is off to commission the first Alpha; automatic allocation remains off.

Apple Alpha records: iOS `6810300888`, macOS `6810302118`. Both have an external
Public Alpha group. TestFlight distribution is Alpha-only; Stable candidates
are processed for App Store submission without beta-group assignment. Existing
tester membership is preserved. Public
Alpha links live in the README only; the website and Homebrew advertise Stable.

## Alpha

After activation, every successful main push CI allocates an immutable annotated
`alpha-build-N` tag containing a manifest. Independent workers build direct Mac,
Mac App Store and iOS from that exact source. Allocation is idempotent; manual
`rebuild` creates a new build number for an expired or invalid Apple upload.
Hourly reconciliation retries missing deliveries. Apple processing and beta
review are recorded as pending, never as successful shipment.

Direct Mac releases are GitHub prereleases. A single `alpha-latest` JSON pointer
routes Alpha feeds/downloads to immutable assets. It cannot change GitHub Latest,
Stable Sparkle feeds or Homebrew. Late older builds cannot roll back the pointer.

The local Codex Run action launches Alpha with `script/build_and_run.sh`.
Alpha starts without a global recording hotkey; configure one in Settings.

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
5. Direct Mac publishes verified candidate assets and updates Homebrew. Apple
   submissions use `AFTER_APPROVAL`; publication receipts advance Apple note
   baselines only after the exact build is publicly available.

Each surface has its own published baseline. TestFlight delivery, an upload, a
review submission and a rejected version do not advance it. Initial Apple Store
releases therefore include the full initial history. Paired reverts cancel only
within the unpublished range. Candidate receipt hashes guard source, build and
notes; direct assets are checked against recorded SHA-256 before promotion.

## Required rollout evidence

Before enabling allocation, verify Alpha profiles contain only Alpha groups and
cloud containers; deploy the matching CloudKit schemas; build signed archives on
all three surfaces; install Alpha alongside Stable on target devices; verify data
and permission isolation; exercise direct Mac Alpha N to N+1 updates; and confirm
public TestFlight availability. Store beta links without an available approved
build are setup evidence only.

Required Alpha signing secrets are selected in the reusable Apple workflows.
No signing material belongs in source control. Use the existing secure API key
and local Apple Developer authentication for provisioning.
