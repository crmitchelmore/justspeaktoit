# iOS Keyboard v2: In-Keyboard Dictation Design

> **Shipping status:** the keyboard extension is included in iOS release builds
> and uses Instant Dictation handoff. The containing app owns microphone capture
> and transcription, and returns a nonce-scoped result through the selected
> release train's App Group. Shipping builds set `TUIST_IOS_KEYBOARD=1` and
> `TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=0`, so the extension neither reads nor asks
> for microphone or Speech permission. Physical handoff qualification remains
> required by [iOS keyboard verification](ios-keyboard-mvp-verification.md).

## Shipping decision

`KeyboardCapturePlanner` requires Full Access and a shared container. With the
shipping direct-capture policy disabled it selects handoff before inspecting
microphone permission, Speech permission, or recognizer availability.

| Condition | Shipping result |
| --- | --- |
| No Full Access or no App Group container | **Blocked** — show setup guidance and do not create a handoff request |
| Full Access and container available | **Handoff** — use the containing app's Instant Dictation session |

The reusable iOS release worker receives one immutable `manifest` input. That
manifest selects the train identity; the worker fixes keyboard inclusion on and
direct capture off. Development generation has independent flags, but generating
another shape does not authorise a release-policy change.

The train-specific identities come from
`Sources/SpeakCore/Resources/ReleaseTrains.json`:

| Train | App | Keyboard | App Group |
| --- | --- | --- | --- |
| Alpha | `com.justspeaktoit.ios.alpha` | `com.justspeaktoit.ios.alpha.keyboard` | `group.com.justspeaktoit.ios.alpha` |
| Stable | `com.justspeaktoit.ios` | `com.justspeaktoit.ios.keyboard` | `group.com.justspeaktoit.ios` |

TestFlight distribution is Alpha-only under the current release-train policy.
Stable candidates use the separate approval and App Store release gates in
[Alpha and Stable release trains](alpha-stable-release-trains.md).

## Why the keyboard hands off

Keyboard v1 (PRs #567–#569) built around an app-owned recorder:

1. The containing app keeps an `AVAudioEngine` Instant Dictation session ready.
2. The keyboard writes a nonce-scoped command into the train's App Group.
3. The app records and transcribes with the selected app profile.
4. The app writes the matching result back, and the keyboard inserts it once.

This architecture has known costs: Full Access and initial setup are required;
the ready session shows the microphone indicator; force quit, restart, or audio
interruption can require reconnecting the app; and the heartbeat, request expiry,
and notification transport introduce states that the UI must explain truthfully.
Those costs are accepted for the supported keyboard because microphone capture
belongs to the containing app.

Issue #991 records that the attempted replacement premise did not hold: its
physical investigation found the custom keyboard could not activate the
microphone and received runtime error 561145187. Repository inspection here does
not independently reproduce that device result. The shipping decision treats the
recorded finding as the current platform evidence and does not present direct
capture as a pending rollout step.

## Shipping handoff

`KeyboardHandoffController` in the extension and
`KeyboardInstantDictationCoordinator` in the app implement the supported path.
Every request snapshots its chosen app profile, language, transcription model,
and post-processing selection. The app either executes that snapshot or returns
`profileUnavailable`; it does not silently substitute another model.

The transport uses nonce-scoped App Group records. Request, transcription, and
result lifetimes are 180, 90, and 60 seconds respectively. A stale, expired, or
cancelled result cannot land in a later request or a different target. Interim
text may appear in the keyboard strip, while the completed transcript is inserted
once through the document proxy.

The App Group also carries language selection and a schema-versioned, non-secret
profile projection. It never carries audio, credentials, custom prompts, or
surrounding host text. Credentials remain in the containing app's Keychain.

### Profile and language controls

`KeyboardDictationPreferencesStore` mirrors the spoken-language preference and a
ring of recent languages. `KeyboardDictationProfileCatalog` defines the profile
choices the app publishes to the keyboard. With direct capture disabled, planner
selection remains handoff: labels and available choices must reflect the
published capability snapshot and the app model that will execute the request.
The UI must not promise that a `Local` selection runs inside the extension.

### Surface

The compact keyboard is about 170 points high in portrait on iPhone:

- **Strip:** interim transcript while dictating; state or setup copy otherwise;
  inline Cancel during a request.
- **Control row:** globe (when required) · language chip · profile chip · mic/stop
  · delete · return. Each control keeps a 44-point touch target. There is no
  QWERTY layer; the globe key returns to a system keyboard for typing.

Full Access is a hard requirement because it gates the shared App Group
container. Without it, the keyboard shows the blocked state and may write only
the observation record used by the setup screen; it creates no request,
transcript, or audio.

## Retained direct-capture experiment

The direct implementation remains behind `IOS_KEYBOARD_DIRECT_CAPTURE`, and CI
compiles that flagged shape to prevent source rot. In the shipping shape,
`KeyboardDictationEngine` compiles as a stub that reports permissions denied and
refuses to start. Compilation proves only that the guarded code builds; it does
not prove microphone access in a keyboard extension.

Historically, the experiment combined `AVAudioEngine`, Apple Speech, the
`KeyboardDictationMachine` state machine, and stable-prefix/tail replacement in
the host document. Its permission, on-device recognition, interruption, memory,
and host-edit behavior is retained as design evidence, not as supported product
behavior or a release roadmap.

Any reconsideration requires all of the following before a rollout proposal:

1. new, supported platform evidence that keyboard-extension microphone capture
   is available;
2. a separately scoped implementation review if platform behavior requires code
   changes;
3. dedicated physical-device qualification of permissions, transcription,
   editing safety, interruptions, accessibility, and memory; and
4. explicit release approval for a policy change.

Until then, permission denial or direct-engine branches describe a compatibility
experiment. They are not a fallback tier exercised by shipping builds.

## Privacy and review posture

- The containing app owns recording and indicates when its Instant Dictation
  microphone session is ready. The keyboard extension does not request microphone
  or Speech permission in the shipping build.
- The keyboard reads bounded context around the cursor only to protect insertion
  and replacement anchors. It does not persist or transmit that host context.
- The App Group contains short-lived handoff records, language selection, and the
  non-secret profile projection. It contains no audio, credentials, custom
  prompts, or surrounding text.
- Direct-capture builds add microphone and speech-recognition usage strings to
  the extension Info.plist. Handoff builds omit them.

## Open shipping risks and physical gates

1. **Readiness and recovery:** after force quit, restart, or audio interruption,
   the keyboard must leave the host unchanged and show actionable reconnect copy.
2. **Result targeting:** nonce, expiry, target changes, cursor movement, and host
   edits must never cause duplicate insertion or mutation in the wrong field.
3. **Host restrictions:** secure fields, phone pads, and apps that prohibit custom
   keyboards must continue to use the system keyboard.
4. **Accessibility and layout:** VoiceOver labels, 44-point touch targets,
   Accessibility text sizes, and iPhone/iPad layouts need physical verification.
5. **Memory:** record a two-minute handoff observation with measured resident and
   peak memory and no jetsam. The project's below-60-MB target is a qualification
   target, not a claimed Apple limit.

Static source review cannot satisfy these gates. Record the exact manifest,
source, train, signed build, device/OS, host/version, tester, and PASS/FAIL/PENDING
evidence described in the verification runbook.
