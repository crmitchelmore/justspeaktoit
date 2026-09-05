# Release gates and recovery

## Before publication

Auto Release waits for successful **CI** on a push to `main`, checks out that
run's commit, and checks that it is still current `main`. It checks the latest
CI run for that exact SHA again immediately before creating the `mac-v*` tag.
The automatic iOS dispatch builds that same tag. Manual Auto Release runs on
`main` pass the same check; they cannot bypass failed or unfinished CI.

If main advanced, let CI finish on the new head. If CI failed, fix the cause
through a PR, then let the new main run complete. A successful rerun of CI also
triggers Auto Release. Version allocation is serialized; non-releasable commits
do not create another tag. The tag remains the source of truth if the optional
`VERSION` commit is rejected by branch protection.

The protected **Build & Test (macOS)** context aggregates debug compilation,
Release tests, both core-journey gates, iOS builds, lint, and public API checks.
Only explicitly path-excluded PR gates (and the PR-only API check on main) may
skip. A failed, cancelled, missing, or unexpectedly skipped job blocks that
protected context. Main pushes always require the Release and journey gates.

Manual macOS tags still run the Release-configuration test suite before signing.
Keep that gate: automatic CI validation does not cover manually created tags.

## Failed release

1. Record the run URL, tag, commit SHA, failed step, and whether a GitHub Release
   already exists. Check its actual assets before deciding to retry.
2. If publication has **not** happened, fix infrastructure/signing problems and
   rerun the failed release workflow from the same tag. A source fix needs a new
   PR and version; do not move an existing release tag.
3. If only the optional CLI build failed, use **Publish speak CLI** with the
   existing version. The workflow creates a follow-up issue with this recovery
   path. Do not rebuild the app just to repair CLI assets.
4. If a failure occurs **after** publication, the release may already be serving
   users. Repair that failed integration separately. Rerunning the entire build
   can replace DMGs and appcasts under the existing tag with a new build number,
   leaving previously downloaded files or Homebrew checksums inconsistent.
5. For an iOS dispatch failure, run **Release iOS (TestFlight)** from the intended
   release tag, with that tag as `release_notes_source_tag`, and verify the
   intended version/build in App Store Connect. Follow
   [the TestFlight runbook](ios-testflight-release.md) for signing and uploads.

## Contain a published macOS regression

The website's two stable appcasts and download URLs redirect to GitHub's latest
release. The separate Homebrew tap has its own version and checksums. Reverting
application source alone does not change either distribution channel.

1. Stop pending publication for the affected release while investigating. Check
   active Auto Release, Release macOS App, and Publish speak CLI runs; a newer
   publication can overwrite a repaired latest pointer or tap entry.
2. Identify the previous known-good release and verify that both DMGs and both
   appcasts are present. Save the current release metadata and tap commit before
   changing distribution pointers.
3. Set the known-good GitHub Release as **Latest**, then verify both website
   appcast redirects and both download redirects resolve to its assets. Keep the
   bad release/tag available for diagnostics; changing the pointer need not
   delete or rewrite them.
4. Restore the Homebrew cask to its known-good version and the checksums of the
   actual published files. Review the CLI formula separately if it was also
   affected. Verify the resulting cask URLs and checksums.
5. Ship a forward fix (or a source revert) as a new version through normal PR and
   CI gates. Repointing the feed contains new installs and offers; it does not
   downgrade already-upgraded clients because Sparkle compares build numbers.
   For affected installations needing immediate replacement, use the local
   backup/install/launch procedure in `AGENTS.md`.

## Current verification limits

- macOS packaging verifies architectures, signatures, entitlements, launch, and
  notarization. Before publication, both signed DMGs must pass a Sparkle
  installation round trip using their exact bytes served on loopback. Both the
  bundle and executable must have changed filesystem identities before their
  signatures and installed versions are checked. Missing
  smoke support fails this gate. The separate post-publication job additionally
  downloads the public arm64 DMG and feed to check delivery. A failure of that
  later delivery check still requires containment.
- Both smoke runs execute on the CI host architecture. The universal DMG's Intel
  slice is verified structurally, but its execution is not proven by an Apple
  Silicon smoke runner. The synthetic feed changes its advertised build number;
  this tests self-installation, not migration from every previously shipped app.
  GUI relaunch observation remains advisory on headless CI; replacement is a
  required, independently observed condition.
- The release workflow does not invoke `scripts/check-crash-rate.sh`. Run it
  separately with the exact Sentry identity, for example
  `scripts/check-crash-rate.sh 'justspeaktoit-mac@2.30.1+202609051234'`, and the
  monitoring token. It queries EU release health for the configured project and
  exits 0 only with measured sessions meeting the threshold (99% by default).
  Exit 1 means a below-threshold measurement; exit 2 means missing or invalid
  evidence, including no sessions. Do not interpret a green release workflow as
  evidence of a measured crash-free rate.
- A successful TestFlight export means the upload completed. Apple's processing,
  tester availability, and physical-device behavior still need the checks in
  the iOS runbook.
