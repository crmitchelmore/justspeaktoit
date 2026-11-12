# iOS TestFlight release and signing runbook

Use this runbook to verify an iOS archive produced by the manifest-based release
pipeline and to diagnose app, widget, or keyboard provisioning failures. The
reusable **Release iOS (TestFlight)** worker is a `workflow_call` target with one
required `manifest` input. Release controllers allocate that immutable manifest;
the worker does not accept manual version, keyboard-inclusion, or direct-capture
inputs.

The worker always sets `TUIST_IOS_KEYBOARD=1` and
`TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=0` on every train, so the keyboard uses
Instant Dictation handoff and makes no microphone or Speech permission attempt
inside the extension: Apple gives a custom keyboard no microphone access, even
with Full Access. Physical acceptance is defined in
[iOS keyboard verification](ios-keyboard-mvp-verification.md).

Alpha builds also carry two preview targets for owner review: the Apple Watch
app with its complication (`TUIST_WATCH_APP=1`) and the Share extension
(`TUIST_IOS_SHARE_EXTENSION=1`). Stable sets both to `0`. See
[Alpha preview targets](#alpha-preview-targets).

## Release controllers and identifiers

[Alpha and Stable release trains](alpha-stable-release-trains.md) is the current
controller and approval runbook. TestFlight distribution is Alpha-only. Stable
candidates are processed for App Store submission under their separate owner
approval gates and are not assigned to a TestFlight group.

`Sources/SpeakCore/Resources/ReleaseTrains.json` is the identity source used by
`scripts/release-train.mjs`:

| Train | App | Widget | Keyboard | App Group |
| --- | --- | --- | --- | --- |
| Alpha | `com.justspeaktoit.ios.alpha` | `com.justspeaktoit.ios.alpha.JustSpeakToItWidgetExtension` | `com.justspeaktoit.ios.alpha.keyboard` | `group.com.justspeaktoit.ios.alpha` |
| Stable | `com.justspeaktoit.ios` | `com.justspeaktoit.ios.JustSpeakToItWidgetExtension` | `com.justspeaktoit.ios.keyboard` | `group.com.justspeaktoit.ios` |

The release configuration exports the selected app as `BUNDLE_ID`, its group as
`IOS_APP_GROUP`, and its cloud container as `IOS_CLOUD_CONTAINER`. Use those
values when inspecting profiles or archives. Do not validate Alpha artifacts
against Stable identifiers.

Do not commit certificates, private keys, decoded profiles, or base64 profile
contents.

## Provisioning profiles

`release-ios.yml` fetches the app, widget and keyboard App Store profiles at
build time with `scripts/ensure-ios-app-store-profile.rb`. For each App ID it
reuses any ACTIVE App Store profile that includes the imported distribution
certificate (matched by serial) and carries the required App Group and iCloud
containers. Otherwise it deletes its own profile (`<bundle id> App Store
<serial suffix>`) if present and creates it again, which picks up the App ID's
current capabilities; it never deletes profiles it did not name. The stored
profile secrets are used only when that fetch fails, for example for an older
frozen source without the script. The job summary lists each profile's source,
iCloud containers and App Groups.

To regenerate and check both trains' profiles outside a release, run the
**Apple App IDs and profiles** workflow (`apple-profiles.yml`). Its Alpha
summary also reports whether each preview target below is ready.

## Alpha preview targets

| Target | Alpha bundle id | App Group | Profile file |
| --- | --- | --- | --- |
| Share extension | `com.justspeaktoit.ios.alpha.share` | `group.com.justspeaktoit.ios.alpha` | `ios-share-appstore` |
| Watch app | `com.justspeaktoit.ios.alpha.watchkitapp` | `group.com.justspeaktoit.watch.alpha` | `watch-appstore` |
| Watch complication | `com.justspeaktoit.ios.alpha.watchkitapp.widget` | `group.com.justspeaktoit.watch.alpha` | `watch-widget-appstore` |

The **Select Alpha preview targets** step turns both flags on for Alpha only.
Profiles are then fetched with `ensure-ios-app-store-profile.rb --register`,
which registers a missing App ID and enables App Groups on it. The API cannot
link a specific App Group to an App ID, so the profile must also carry the
target's group. Every one of these is optional for the release:

- If the selected source predates train-aware signing for a target, or its
  profile cannot be fetched with the right group, Alpha is built without that
  target. The watch app needs both watch profiles.
- The step summary records each decision, for example
  `Watch app included: 0 (reason: no App Store profile for … with
  group.com.justspeaktoit.watch.alpha …)`.
- When a target is included, the archive must embed it with the manifest
  version/build and its App Group, and export maps its profile.

To bring a missing target in, link its App Group to its App ID in the Apple
Developer portal (see [Watch provisioning](watch-provisioning.md)), then rerun
`apple-profiles.yml`. The next Alpha build picks it up.

## Verify an authorised iOS release

1. Identify the existing authorised manifest tag and retain its source SHA,
   train, iOS version/build, and controller workflow URL. Do not call the
   reusable worker ad hoc.
2. Confirm the worker checked out the manifest and
   `scripts/release-train.mjs configure --tag <manifest> --surface ios` selected
   the expected source and train identity.
3. Monitor the signing and archive gates:
   - distribution certificate and train-specific app, widget, and keyboard
     profiles install successfully;
   - the keyboard profile authorises `IOS_APP_GROUP` for
     `BUNDLE_ID.keyboard`;
   - app, widget, and keyboard archive with the manifest version/build;
   - all three products retain `IOS_APP_GROUP`, and the app retains
     `IOS_CLOUD_CONTAINER`;
   - the archive contains `JustSpeakKeyboard.appex` and the step summary
     reports direct capture disabled; and
   - export and App Store Connect upload succeed.
4. Keep upload, Apple processing, beta review, and public TestFlight availability
   as distinct states. Confirm the exact Alpha version/build reaches the intended
   tester group before installation.
5. Install or update that processed Alpha build on a physical iPhone. Record the
   installed train/version/build, then run the physical keyboard checks below.

An upload or green workflow is not proof that Apple processed, distributed, or
physically verified the build.

## Named Alpha testers

Owner-nominated testers live only in the `TESTFLIGHT_TESTER_EMAILS` secret
(comma-separated) of the main-only `testflight-testers` environment; the
repository is public, so never commit or log an address. Only jobs in that
environment read it, and they log counts and Apple states only.

- After a successful iOS Alpha upload, `alpha-release.yml`'s `ios-testers` job
  adds the testers to the external **Public Alpha** group and sends invitations.
  An invitation Apple refuses because no build is testable yet stays pending.
- **TestFlight tester access** (`testflight-testers.yml`, manual from `main`)
  repeats that, runs the Apple reconciler (assignment and beta review), and
  verifies membership, invitation and that the newest valid build is in or
  waiting for beta review, or testable and assigned to Public Alpha. When no
  recent valid build exists it starts a hosted iOS Alpha rebuild (unless one is
  already running) and fails; rerun it after TestFlight processing.

## Repair a keyboard App Group profile

Use this sequence when the workflow reports that the keyboard profile does not
authorise the selected App Group or when archive/export reports an entitlement
mismatch.

1. From the failed workflow's release evidence, identify `RELEASE_TRAIN`,
   `BUNDLE_ID.keyboard`, and `IOS_APP_GROUP`.
2. In Apple Developer **Certificates, Identifiers & Profiles**, open that exact
   keyboard identifier. Enable App Groups, associate the exact selected
   `IOS_APP_GROUP`, save, and confirm the association.
3. Run the **Apple App IDs and profiles** workflow, or retry the release: both
   replace a profile that lacks the group, since enabling the capability alone
   does not update an existing profile's entitlement. The workflow also checks
   the app's profile, so an unrelated app-profile problem fails it first.
4. The stored `ALPHA_IOS_KEYBOARD_APPSTORE_PROFILE` and
   `IOS_KEYBOARD_APPSTORE_PROFILE` secrets are only a fallback; the workflow
   still fails closed unless the profile contains the expected group.
5. Retry through the release controller for the same authorised manifest or its
   documented rebuild path. Record the new workflow and build allocation.

Prefer updating and validating the correct profile over deleting profiles, which
can disrupt other release paths.

## Verify a downloaded profile

Decode only the entitlements dictionary. Converting a complete profile to JSON
can fail because embedded certificate values are binary.

```bash
PROFILE_PATH=/path/to/keyboard.mobileprovision
EXPECTED_APP_GROUP='<IOS_APP_GROUP from release evidence>'
PROFILE_PLIST=$(mktemp)
security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST"
plutil -extract Entitlements xml1 -o - "$PROFILE_PLIST" \
  | grep -Fq "<string>$EXPECTED_APP_GROUP</string>"
```

The command must exit successfully. Also compare the profile's application
identifier with `<APPLE_TEAM_ID>.<BUNDLE_ID>.keyboard`. The release worker makes
equivalent identity and entitlement checks before archiving.

## Physical-device keyboard checks

1. Install the exact processed and tester-assigned Alpha build. Confirm its
   manifest, source, version, build, and Alpha identity.
2. In iOS Settings, enable **Just Speak Alpha** under **General** ›
   **Keyboard** › **Keyboards**, grant Full Access, and complete the app's
   current Instant Dictation setup.
3. In Notes, WhatsApp, and the other required matrix hosts, select the keyboard
   and start dictation. The extension must not present microphone or Speech
   permission. Treat such a prompt as a failure.
4. Confirm the containing app records through the iPhone microphone, the keyboard
   shows the ready/request state truthfully, and the nonce-matched result returns
   through `group.com.justspeaktoit.ios.alpha` and inserts once at the intended
   cursor/selection.
5. With Instant Dictation not ready, confirm actionable reconnect guidance and no
   host mutation. Confirm cancel, stale result, target switching, interruption,
   secure-field, globe, accessibility, and memory behavior through the complete
   [physical shipping matrix](ios-keyboard-mvp-verification.md#physical-shipping-matrix).

The supported path is keyboard → containing app microphone/transcription →
nonce-scoped App Group result → document-proxy insertion. The retained direct
code is a historical experiment and is not part of normal release verification.

## Build-based rollback

There is no runtime removal or policy switch for an already installed keyboard.
A rollback requires an authorised source or release-policy change, review, and a
new correctly signed build through the existing manifest/controller process.

For a handoff regression, select or build an authorised replacement through the
Alpha controller and verify its archive, processing, tester assignment,
installation, and physical behavior independently. Removing the extension or
changing direct-capture policy is a repository policy decision; do not emulate it
with an ad hoc call to the reusable worker.

## Completion evidence

Report each state separately:

- authorised manifest, source SHA, train, version/build, and controller run;
- reusable worker success and release-policy summary;
- archive identities, extension presence, and entitlements;
- App Store Connect upload, processing, beta review, and tester availability;
- exact build installed on each physical device; and
- handoff, insertion, recovery, system restriction, accessibility, and memory
  rows from the physical matrix.

If a later state is not verified, mark it PENDING rather than treating an earlier
green gate as shipment. Documentation review does not satisfy physical-device
acceptance or authorise a new Alpha or Stable release.
