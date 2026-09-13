# iOS Custom Keyboard Handoff Verification

This runbook qualifies the keyboard shape that ships today: the extension is
included and uses Instant Dictation handoff to the containing app. The release
worker sets `TUIST_IOS_KEYBOARD=1` and
`TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=0`; the keyboard extension does not capture
audio or request microphone or Speech permission.

Architecture and path selection are documented in
[iOS Keyboard v2 design](ios-keyboard-v2-design.md). Instant Dictation behavior
is documented in
[iOS Keyboard Instant Dictation](ios-keyboard-instant-dictation.md). Release
identity and approval rules are controlled by
[Alpha and Stable release trains](alpha-stable-release-trains.md).

## Scope and completion rule

The physical gate verifies Full Access and container setup, ready and not-ready
handoff, nonce-scoped result delivery, host-edit safety, interruptions, system
restrictions, accessibility, layout, and memory. It does not authorise a release,
change a feature flag, or establish direct microphone access in an extension.

Documentation and static source review may complete while hardware rows remain
pending. Do not close the physical qualification from simulator, CI, archive, or
source evidence.

Record one row per device and host scenario with:

- immutable manifest tag, source SHA, train, marketing version, and build;
- workflow URL and signed archive evidence;
- app, keyboard, and App Group identities from that release;
- tester, device model, exact OS, host app and version, and timestamp;
- PASS, FAIL, or PENDING plus screenshots, recording, console, or memory evidence.

Minimum coverage is:

- one physical iPhone at the supported iOS 17 floor;
- one physical iPhone on the tested current iOS;
- Notes and WhatsApp on both iPhones, and Safari on the newer iPhone; and
- one current-iPadOS iPad for full-width/split layout and VoiceOver.

A missing row remains PENDING. Never infer a pass.

## Source and build verification

The reusable **Release iOS (TestFlight)** workflow accepts only a required
`manifest`. It loads that immutable manifest, configures the selected release
train, and fixes keyboard inclusion on and direct capture off. There are no
`include_keyboard` or `enable_direct_capture` inputs.

For a local development build of the shipping shape:

```bash
TUIST_IOS_KEYBOARD=1 \
TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=0 \
tuist generate --no-open
```

Generating a development project is separate from building or uploading an
authorised release. To exercise the existing simulator suites after generation:

```bash
xcodebuild test \
  -workspace "Just Speak to It.xcworkspace" \
  -scheme SpeakiOS \
  -destination "platform=iOS Simulator,id=<BOOTED_UDID>" \
  -only-testing:SpeakiOSTests \
  -only-testing:SpeakiOSUITests
```

The pure keyboard and distribution checks can also be selected with:

```bash
swift test --filter Keyboard
swift test --filter DistributionBuildIdentityTests
```

These checks support source review; they do not replace the physical gate.

Before testing a release build, read its manifest/configuration evidence. Match
the identities selected by `Sources/SpeakCore/Resources/ReleaseTrains.json`:

| Train | App bundle | Keyboard bundle | App Group |
| --- | --- | --- | --- |
| Alpha | `com.justspeaktoit.ios.alpha` | `com.justspeaktoit.ios.alpha.keyboard` | `group.com.justspeaktoit.ios.alpha` |
| Stable | `com.justspeaktoit.ios` | `com.justspeaktoit.ios.keyboard` | `group.com.justspeaktoit.ios` |

TestFlight distribution is currently Alpha-only. Do not validate an Alpha build
against the Stable App Group. Stable candidates follow their separate release
gate and are not assigned to a TestFlight group.

Inspect the signed archive or installed product and retain evidence that both
extensions are present:

```bash
find "<JustSpeakToIt.app>/PlugIns" -maxdepth 1 -type d -name '*.appex' -print
```

Expected entries are `JustSpeakKeyboard.appex` and
`JustSpeakToItWidgetExtension.appex`. Confirm the app, widget, and keyboard use
the manifest-selected `IOS_APP_GROUP`, the keyboard bundle equals
`BUNDLE_ID.keyboard`, and the app retains the manifest-selected iCloud
container. Use the release evidence values; do not substitute a hard-coded
Stable identifier.

## Physical shipping matrix

### Installation and Full Access

1. Install the exact processed, tester-assigned build and confirm its train,
   version, and build in the app.
2. Launch Just Speak and open Settings › Set Up Keyboard. Add the keyboard,
   enable Full Access, and complete the app's current Instant Dictation setup.
3. Open the keyboard once and confirm the setup screen reports the observed
   state.
4. Turn Full Access off. The keyboard must show the explanatory blocked state,
   never claim it can record, and create no handoff request or transcript.
   The `hadFullAccess: false` observation record used by setup is the only
   permitted write.
5. Restore Full Access and reopen the keyboard. Confirm the observation and
   readiness UI update without promising an extension permission prompt.

### Handoff ready and not ready

1. With Instant Dictation ready, open the keyboard in the host. The shipping
   path must select handoff without presenting microphone or Speech permission
   from the extension.
2. Start dictation. Confirm the containing app owns microphone capture, interim
   text is mirrored in the strip where available, and Stop & Insert places the
   final transcript once at the current target.
3. Confirm History identifies the chosen app model and contains the completed
   handoff.
4. Cancel before completion. The host must remain unchanged and a later request
   must still work.
5. Force quit the containing app, restart the device, and trigger an audio
   interruption in separate rows. When Instant Dictation is not ready, the
   keyboard must show actionable reconnect guidance and leave the host unchanged.
6. Reconnect in the app and verify a new request completes without reusing a
   prior interim or final result.

### Nonce and result-targeting safety

For every text assertion, record the initial host content and selection and the
final content and selection.

1. Dictate into an empty field and after existing text with and without trailing
   whitespace. Confirm the intended separator and transcript appear once.
2. Dictate a second utterance. It must append cleanly without changing the first.
3. Place the caret within existing text and replace a selection. Verify the
   selected/caret text and surrounding content are preserved as designed.
4. Use composed Unicode, including a multi-scalar emoji, adjacent to the target.
   No partial scalar, unrelated text, or duplicate separator may remain.
5. Change field, app, or keyboard while a request is active. The request must
   cancel or become ineligible; its result must not land in the new target.
6. Move the caret or edit text around the target during a request. If the stored
   anchor can no longer be proved, no best-effort mutation is permitted.
7. Submit a newer request before an older result arrives. Only the exactly
   nonce-matched current result may insert.
8. Verify expiry behavior: requests live 180 seconds, transcription 90 seconds,
   and results 60 seconds. Expired records must not insert.

### Language and profile controls

The app publishes a non-secret capability snapshot. In the shipping policy all
capture uses handoff, so verification follows what the current UI actually
offers and which app-owned model the request snapshots. A label such as `Local`
must not be interpreted as Apple Speech running inside the extension.

1. Change the spoken language in the app, then open another app's keyboard
   without relaunching Just Speak. Confirm the keyboard reflects the published
   language and any available quick-switch choices.
2. Exercise each displayed language/profile choice within its advertised tap
   count. Controls must be disabled while a request is active where required.
3. For each chosen profile, compare the request snapshot and History with the
   app's exact transcription model, language, and post-processing selection.
4. Select a model whose credential or capability is unavailable. The keyboard
   must report the profile unavailable and must not silently substitute another
   model.
5. Confirm capability and profile records contain identifiers, display metadata, language,
   and route only. They must contain no API key, token, custom prompt, audio, or
   surrounding host text.
6. Kill and reopen the keyboard. A valid selection should survive; a retired
   choice must fall back visibly according to the published catalogue.

### Interruptions and recovery

1. Receive a call or trigger Siri during handoff. Confirm the request terminates
   truthfully, the host is not partially or incorrectly changed, and the next
   request can start after readiness returns.
2. Dismiss the keyboard or switch keyboards mid-request. Confirm cancellation
   and no late insertion.
3. Exercise app force quit, device restart, network loss for a cloud model, and
   provider failure. The keyboard must give safe recovery guidance and logs must
   contain no credential, provider body, nonce, transcript, or host context.
4. Confirm temporary batch audio is removed after success and cancellation.

### System limits, layout, and accessibility

Confirm Just Speak is absent and the system keyboard remains active in secure
password fields, phone-pad fields, and an app known to disable third-party
keyboards.

Verify portrait and landscape on iPhone; split and full-width layout on iPad;
light and dark appearance; large Accessibility text sizes; globe switching;
delete and return behavior; VoiceOver names and start/stop state for each key;
and touch targets of at least 44 points. Include first-use setup and recovery
copy in the VoiceOver pass.

### Memory observation

Observe the keyboard extension for at least two minutes while repeated handoff
requests run. Record resident and peak memory at 30-second intervals and whether
jetsam occurred. Below 60 MB with no sustained final-minute rise and no jetsam is
the project's qualification target, not an Apple-guaranteed extension limit.
Do not use measurements from the direct-transcription experiment as handoff
evidence.

## Privacy and App Review evidence

- `RequestsOpenAccess` supports the train's App Group and the app-owned handoff.
  It does not grant the extension microphone access.
- Shipping extension Info.plist output omits microphone and Speech usage strings.
- Recording belongs to the containing app's ready Instant Dictation session.
- App Group handoff records are nonce-scoped and short-lived. Surrounding host
  text, audio, credentials, and custom prompts do not enter the container.
- No private settings URL, responder-chain workaround, Apple keyboard asset, or
  unsupported containing-app launch is used.
- Review notes should describe the handoff path, Full Access, readiness setup,
  and secure-field/phone-pad/host restrictions exactly as users see them.

## Conditional historical direct-capture experiment

The repository retains direct-capture code behind
`IOS_KEYBOARD_DIRECT_CAPTURE`, and CI compiles the flagged shape. Issue #991
records that physical investigation could not activate microphone capture from
the custom keyboard. This appendix preserves the former qualification intent;
it is not an instruction to make a TestFlight build or flip a release flag.

Do not run or publish this experiment unless all prerequisites are met:

1. new supported platform evidence establishes keyboard-extension microphone
   access;
2. any necessary code work receives its own scope and review;
3. a dedicated physical build is authorised for permission, happy-flow,
   language, editing, interruption, accessibility, offline, and two-minute
   direct-engine memory tests; and
4. a separate rollout decision explicitly approves a release-policy change.

If those gates are met later, record fresh-install microphone and Speech prompt
behavior; grants and denials; on-device and server-only locale behavior; streamed
stable-prefix/tail edits; stop, cancel, target changes, composed Unicode, and
audio-session release. Measure the direct engine independently. A successful CI
compile cannot satisfy any physical or rollout prerequisite.

## Rollout boundary

The documentation correction is complete after source, identity, command,
heading-anchor, and relative-link review. Hardware acceptance remains open until
real rows satisfy the physical shipping matrix. Any rollback or policy change
requires an authorised source change and a new correctly signed build through
the existing manifest-based release process; an installed extension cannot be
changed remotely.
