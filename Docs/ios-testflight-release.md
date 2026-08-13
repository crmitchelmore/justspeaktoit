# iOS TestFlight release and signing runbook

Use this runbook for normal TestFlight releases and for failures involving the iOS app, widget, or transcription keyboard provisioning profiles.

Normal automated and manual releases include the keyboard extension. Direct
capture inside the extension is independently disabled until the physical
matrix in [iOS keyboard verification](ios-keyboard-mvp-verification.md) passes;
the shipping keyboard uses Instant Dictation handoff and makes no extension
microphone or Speech permission attempt.

## Release identifiers

| Component | Bundle identifier | Required shared capability |
| --- | --- | --- |
| iOS app | `com.justspeaktoit.ios` | App Group and iCloud |
| Widget | `com.justspeaktoit.ios.JustSpeakToItWidgetExtension` | App Group |
| Keyboard | `com.justspeaktoit.ios.keyboard` | App Group |

The shared App Group is `group.com.justspeaktoit.ios`. The keyboard App Store profile name starts with `JustSpeakToIt Keyboard App Store`.

Do not commit certificates, private keys, decoded profiles, or their base64 contents.

## Normal release

1. Confirm the intended commit is on `main` and its required checks passed.
2. Open App Store Connect and check the latest iOS TestFlight marketing version and build number.
3. Run the GitHub Actions workflow **Release iOS (TestFlight)**. Enter the intended semantic version explicitly, without a leading `v`. Keep `include_keyboard=true`. Keep `enable_direct_capture=false` unless this exact build is the recorded direct-capture matrix build. The repository `VERSION` file is not authoritative for iOS.
4. Monitor all distribution gates in the workflow:
   - signing certificate and three profiles install successfully;
   - the keyboard profile authorizes `group.com.justspeaktoit.ios`;
   - the app, widget, and keyboard archive with the requested version and build;
   - all three archived products retain the shared App Group entitlement, and the app retains `iCloud.com.justspeaktoit.ios`;
   - export and upload to App Store Connect succeed.
5. Wait for Apple processing to finish. Confirm the exact version and build are visible in App Store Connect and assign the build to the intended internal TestFlight group.
6. Update the app from TestFlight on a physical iPhone. Confirm the installed version/build, enable the keyboard, and run the device checks below.

An upload is not the completion signal. Processing, tester assignment, installation, and hardware validation are separate gates.

## Repair a keyboard App Group profile

Use this sequence when the workflow reports that the keyboard provisioning profile does not authorize the shared App Group or when archive/export reports an entitlement mismatch.

1. In the Apple Developer portal, open **Certificates, Identifiers & Profiles** → **Identifiers** → `com.justspeaktoit.ios.keyboard`.
2. Enable **App Groups**, choose **Configure**, associate `group.com.justspeaktoit.ios`, then save and confirm the identifier change.
3. Open **Profiles**, select the App Store profile whose name starts with `JustSpeakToIt Keyboard App Store`, choose **Edit**, and save or regenerate it. Enabling the capability through the App Store Connect API alone does not reliably attach the App Group to the identifier, and an existing profile does not gain the entitlement until it is regenerated.
4. If CI uses the `IOS_KEYBOARD_APPSTORE_PROFILE` GitHub secret, replace it with the base64 of the regenerated profile. If the secret is absent, the workflow may reuse or create a portal profile, but it will still fail closed unless that profile contains the shared App Group.
5. Rerun **Release iOS (TestFlight)** with the explicit intended iOS version.

Prefer reusing and validating the portal profile over deleting profiles. Profile deletion can disrupt other release paths and is not required for this repair.

## Verify a downloaded profile

Decode only the entitlements dictionary. Converting the complete profile to JSON can fail because embedded certificate values are binary data.

```bash
PROFILE_PATH=/path/to/keyboard.mobileprovision
PROFILE_PLIST=$(mktemp)
security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST"
plutil -extract Entitlements xml1 -o - "$PROFILE_PLIST" \
  | grep -Fq '<string>group.com.justspeaktoit.ios</string>'
```

The command must exit successfully. The release workflow performs the same exact entitlement check before archiving.

## Physical-device keyboard checks

1. Install or update the processed build from TestFlight and confirm its version/build in the app.
2. In iOS Settings, enable **Just Speak to It** under **General** → **Keyboard** → **Keyboards**. Enable Full Access only when the app's current onboarding requires it.
3. Open a text field in another app, switch to the Just Speak to It keyboard, and start transcription. In a normal handoff-only build, no microphone or Speech permission prompt may come from the keyboard.
4. Confirm the containing app records through the iPhone microphone, returns the nonce-matched result through the App Group, and the keyboard inserts the text at the cursor. If Instant Dictation is not ready, confirm the keyboard shows the reconnect state and leaves the field unchanged.
5. Confirm stale results are not reused and normal Apple keyboard switching remains available.

Direct extension capture remains an unverified, policy-gated candidate rather
than an assumed platform capability. Run it only with
`enable_direct_capture=true` and complete the separate physical matrix. The
normal supported path is keyboard → containing app → microphone/transcription
→ App Group handoff → `textDocumentProxy.insertText`.

## Build-based rollback

- Direct-capture rollback: run a new build with `include_keyboard=true` and
  `enable_direct_capture=false`; verify handoff on hardware.
- Extension rollback: run a new build with `include_keyboard=false`; verify the
  archive omits `JustSpeakKeyboard.appex`.
- There is no runtime switch for an installed build. Record the replacement
  workflow URL, commit, version/build, processing, tester assignment, physical
  installation, and observed extension state in issue #661.

## Completion evidence

Report each state separately:

- PR merged and release commit identified.
- Release workflow succeeded.
- Workflow summary recorded keyboard inclusion and direct-capture policy.
- Archive presence/absence and keyboard App Group entitlement matched policy.
- App Store Connect processing completed for the exact version/build.
- Internal tester group assignment confirmed.
- TestFlight build installed on a physical iPhone.
- Microphone handoff and keyboard insertion verified end to end.

If a later state is not verified, say so explicitly instead of treating an earlier green gate as shipment.
