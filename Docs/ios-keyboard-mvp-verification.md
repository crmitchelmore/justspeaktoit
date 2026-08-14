# iOS Custom Keyboard v2 Verification

TestFlight includes `JustSpeakKeyboard.appex` by default so automated releases
cannot silently drop an enabled keyboard. Direct capture is an independent,
default-off build policy: normal releases set
`TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=0` and use the proven Instant Dictation
handoff without requesting microphone or Speech permission in the extension.
Generate with `TUIST_IOS_KEYBOARD=1 tuist generate` for that shipping shape;
add `TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=1` only for the direct-capture matrix.

Architecture, path selection, and open risks are documented in
[iOS Keyboard v2 design](ios-keyboard-v2-design.md). The fallback path's
always-ready microphone behaviour is documented in
[iOS Keyboard Instant Dictation](ios-keyboard-instant-dictation.md).

## Scope

The Just Speak keyboard is transcription-first: a live transcript strip plus
one control row (globe · language chip · profile chip · mic/stop · delete ·
return). Each chip appears only when it has somewhere to switch to, and the mic
drops its "Speak"/"Stop" caption while both chips are present so the row stays
one line at the same ~170 pt height. There is deliberately no QWERTY layer; the
globe key returns to a system keyboard for typing. Two capture paths exist
behind `KeyboardCapturePlanner`:

- **Direct** (candidate, policy-gated): the extension records via `AVAudioEngine` and
  transcribes with Apple Speech (on-device preferred), streaming text into the
  host field through stable-prefix commit + tail replacement.
- **Handoff** (fallback): the v1 Instant Dictation flow, used when the
  extension cannot run the microphone or speech recognition.

Both paths require Full Access; without it the keyboard shows setup guidance
and creates no dictation state. The one write it still makes is the observation
record (last seen, `hadFullAccess: false`) that the app's setup screen reads to
show whether the keyboard has ever run — no handoff request, transcript, or
audio.

## Simulator verification

Run from a generated workspace on a booted iOS Simulator:

```bash
TUIST_IOS_KEYBOARD=1 tuist generate --no-open
xcodebuild test \
  -workspace "Just Speak to It.xcworkspace" \
  -scheme SpeakiOS \
  -destination "platform=iOS Simulator,id=<BOOTED_UDID>" \
  -only-testing:SpeakiOSTests \
  -only-testing:SpeakiOSUITests
```

`SpeakiOSTests` contains the injectable keyboard view-model/document-proxy flow
tests, including stale callback, same-field caret, empty capture, policy, and
composed-character scenarios. State-machine, streaming-edit, planner, and
language-preference logic are pure SpeakCore types, while keyboard distribution
guards live in `Tests/SpeakAppTests`; run both through SwiftPM:

```bash
swift test --filter Keyboard
swift test --filter DistributionBuildIdentityTests
```

Verify the installed app contains both extensions:

```bash
find "<JustSpeakToIt.app>/PlugIns" -maxdepth 1 -type d -name '*.appex' -print
```

Expected entries are `JustSpeakKeyboard.appex` and
`JustSpeakToItWidgetExtension.appex`. The nonce, transcript, API keys, and
surrounding text must not appear in logs.

## Physical-device matrix (direct-capture release gate)

Use a development or TestFlight build signed with App Group
`group.com.justspeaktoit.ios` for the app and keyboard extension. The
TestFlight workflow needs a provisioning profile for bundle ID
`com.justspeaktoit.ios.keyboard`. It uses the
`IOS_KEYBOARD_APPSTORE_PROFILE` secret when present, otherwise it reuses or
creates the validated portal profile described in the TestFlight runbook.

Record one row per device/host scenario in issue #661 with the tester's name,
device model, exact iOS version, host app/version, workflow URL, commit SHA,
marketing version/build, pass/fail result, screenshots or screen recording,
and any console/memory evidence. Minimum coverage is:

- one physical iPhone on iOS 17 and one physical iPhone on the current iOS;
- Notes and WhatsApp on both iPhones, plus Safari on the current-iOS iPhone;
- one current-iPadOS iPad for full-width/split layout and VoiceOver checks.

Do not infer a pass from simulator or CI results. A missing row is a failed
release gate, not an implicit pass.

### Handoff-only shipping build

1. Run **Release iOS (TestFlight)** with `include_keyboard=true` and
   `enable_direct_capture=false`.
2. Confirm `JustSpeakKeyboard.appex` is present and carries the App Group
   entitlement, then install the processed build on a physical iPhone.
3. With permissions undecided, tap the keyboard mic. No extension microphone
   or Speech prompt may appear; the first action must select handoff.
4. With Instant Dictation ready, complete dictation through handoff. With it
   not ready, show the actionable reconnect state and leave the host field
   unchanged.

### Enablement and Full Access

1. Launch Just Speak once and open Settings › Set Up Keyboard.
2. Follow the three setup steps (add keyboard, Allow Full Access, first mic
   tap).
3. With Full Access **off**, verify the keyboard shows the explanatory blocked
   state, never claims it can record, and writes no handoff request or
   transcript. The observation record marked "Observed off" may appear in the
   app's setup screen; that is the only permitted write.
4. With Full Access on, verify the observed-status rows update after opening
   the keyboard once.

### Direct path: permissions (open risk — verify first)

Run this section only in an explicitly identified build made with
`enable_direct_capture=true`.

1. Fresh install, Full Access on, no permissions granted. In Notes, open the
   Just Speak keyboard and tap the mic.
2. **Record whether iOS presents the microphone and speech-recognition
   prompts inside the keyboard.** This is the load-bearing platform
   assumption; note OS version and device.
3. Grant both → recording must start with a visible red stop state. Complete
   dictation in Notes and WhatsApp without leaving either host app.
4. With Instant Dictation enabled in the app (Settings › Set Up Keyboard),
   repeat fresh installs denying microphone and Speech separately. Each denial
   must degrade to handoff without hanging and must leave no separator or other
   failed-attempt mutation in the host field.
5. Repeat each denial with Instant Dictation not ready. The keyboard must show
   an actionable reconnect state and leave the host field unchanged.
6. Revoke permissions in Settings afterwards and confirm the keyboard plans
   the fallback path on next appearance.

### Direct path: happy flow

1. In Notes (or WhatsApp for the issue #610 acceptance criterion), tap the
   mic and speak a few sentences.
2. Words must stream into the field as you speak, with the same live text in
   the keyboard strip; earlier words must stop churning once committed
   (stable-prefix behaviour), while the last couple of words may revise.
3. Tap stop → the final transcript replaces the volatile tail only; no
   duplicated or dropped words; cursor ends after the inserted text.
4. Dictate after existing text that lacks a trailing space → a separator space
   is inserted first; after whitespace or in an empty field → no extra space.
5. Tap the mic again and dictate a second utterance → it must append cleanly
   with no deletion of the first utterance.
6. Airplane mode with an on-device Apple Speech locale → dictation still
   works offline. A server-only locale must fail gracefully.
7. Delete and return keys work when idle and are disabled while capturing;
   globe switches keyboards at all times.
8. Dictate text that a later revision must rewrite while a composed emoji
   (for example 👨‍👩‍👧‍👦) sits inside the volatile tail → the emoji is removed
   whole, leaving no fragment behind, and text before the tail is untouched.

### Direct path: language quick-switch

1. In the app, set a spoken language; open the keyboard → the chip shows it.
2. Tap the chip → it cycles to the next quick language in one tap (≤2 taps
   from anywhere in the keyboard). Chip is disabled while recording.
3. Dictate in the switched language and verify recognition uses it.
4. Switch the app language and immediately switch to another app's keyboard
   without reopening Just Speak → the chip and recogniser use the new selection.

### Profile/mode quick-switch

The app publishes one non-secret capability snapshot with two modes. `Local`
runs Apple Speech directly in the extension without post-processing. `App`
routes through Instant Dictation using the app's exact selected transcription
mode/model, spoken language, and post-processing model. API keys stay in the
app Keychain, and the menu remains available without Apple Intelligence.

1. In the app, select a remote streaming or batch model, language, and
   post-processing model. Open the keyboard → its menu shows `App`; the full
   accessibility label names the model and “Via app”, while `Local` says
   “On-device”.
2. Tap the chip, then a mode → each mode is reachable in two taps. The menu is
   disabled from recording start until the result settles.
3. Choose `Local` → Apple Speech streams into the field directly and no
   post-processing runs. Repeat on a device without Apple Intelligence; the
   profile control must still appear and work.
4. Choose `App` with Instant Dictation ready → the app uses the exact model,
   language, and polish model shown in settings; the completed result is
   inserted once. Confirm the handoff record contains identifiers and route
   metadata but no API key, token, prompt, or surrounding text.
5. Select a remote model without its credential → the keyboard reports the
   profile unavailable and does not silently fall back to Apple Speech.
6. Change model, language, or post-processing while the app remains active,
   then switch straight to another app → reopening the keyboard shows the new
   values without requiring an app relaunch.
7. Kill and reopen the keyboard → its last valid `Local`/`App` selection
   survives. If a published mode is retired, the selection visibly falls back
   to the app default instead of retaining stale fields.
8. Switch fields during an App request → the nonce-scoped request is cancelled
   and no result lands in the new destination.

### Direct path: interruptions and target changes

1. Receive a call / trigger Siri mid-dictation → capture ends, words already
   streamed remain, no crash; mic tap starts a fresh session.
2. Switch to a different text field or app mid-dictation → capture cancels,
   already-streamed text stays in the original field, nothing streams into
   the new target.
3. Move the cursor/selection earlier and later in the same field before a
   revising partial. The run must pause or terminate truthfully before another
   replacement, and unrelated host text must remain byte-for-byte unchanged.
4. Edit text before and after the cursor in the host app during capture. Any
   unprovable replacement anchor must pause the run; no best-effort deletion is
   permitted.
5. Dismiss the keyboard mid-dictation → audio session releases (no stuck
   orange indicator).

### Direct path: memory

With the Xcode memory gauge attached to the extension, dictate continuously
for at least two minutes with on-device speech. Record resident and peak memory
at 30-second intervals. The gate is a peak below 60 MB with no sustained rise
over the final minute and no jetsam. A peak of 60 MB or more fails the gate.

### Fallback path (Instant Dictation handoff)

With keyboard microphone permission denied and Instant Dictation enabled in
the app, re-run the v1 checks:

1. Opening the keyboard starts a handoff automatically while ready; live
   interim text appears in the strip; Stop & Insert places the final text at
   the cursor without an app switch; the transcript lands in History.
2. After force quit / restart / interruption, the keyboard truthfully asks for
   one reconnect in the app.
3. Cancel before completion inserts nothing; a newer request still works.
4. Changing app or text field during a handoff cancels rather than inserting
   into the wrong destination.
5. Requests expire per the v1 windows (3 min request, 90 s finalisation, 60 s
   result); expired results are not inserted.
6. Cloud-model handoffs: History identifies the model; failures produce a
   generic safe error; no API key, provider response, nonce, or surrounding
   text in device logs; batch audio removed after success and cancellation.

### System limitations

Confirm Just Speak is absent and the system keyboard remains active in secure
password fields, phone-pad fields, and an app known to disable third-party
keyboards.

Also verify portrait and landscape on iPhone, split/full-width layouts on
iPad, light and dark appearance, large Accessibility text sizes (keyboard
height grows), VoiceOver labels for every key (mic announces start/stop
dictation), and touch targets of at least 44 points.

## App Review and privacy evidence

- `RequestsOpenAccess` is declared so the extension can reach the App Group and
  the network (Apple's server dictation for locales without on-device support,
  and the fallback path's user-selected cloud transcription).
- Microphone capture and Apple Speech inside the extension are *not* granted by
  Full Access. Direct-capture builds declare `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription`; handoff-only builds omit both. The user
  must authorise both permissions when testing direct capture.
  Whether iOS presents those prompts to a keyboard extension — and honours the
  grants — is the unverified platform assumption tracked in "Direct path:
  permissions" above; the handoff path covers devices that refuse.
- When direct capture is enabled, the extension records only while the mic key
  is active and prefers on-device recognition.
- `Local` never routes a transcript to a network post-processor. With direct
  capture enabled it runs in the extension; while direct capture is off or
  unavailable, the app executes the same Apple Speech snapshot. `App`
  explicitly routes the selected model through the containing app; credentials
  stay in Keychain and never enter the App Group.
- The keyboard reads bounded context immediately before and after the cursor
  locally to prove replacement anchors. It never persists or transmits that
  context.
- The App Group contains: versioned handoff records (schema version, request
  UUID, document identifier, timestamps, phase, safe failure enum, throttled
  interim text, short-lived final transcript), the language selection, and a
  schema-versioned profile projection containing identifiers, display metadata,
  language, and explicit route only. Never audio, credentials, prompts, or
  surrounding host text.
- No private settings URL, responder-chain workaround, Apple keyboard asset,
  or unsupported containing-app launch is used.
- App Review notes should describe both capture paths, the permission grants,
  and the secure-field, phone-pad, and host-app restrictions exactly as users
  see them.

## Rollout and rollback

1. Keep automated releases at `include_keyboard=true` and
   `enable_direct_capture=false` until every row above is attached to #661.
2. Use one manual TestFlight build with `enable_direct_capture=true` for the
   direct matrix, recording the workflow URL, commit, version/build, archive
   presence, entitlement, processing/group assignment, installation, and
   extension presence.
3. After the matrix passes, change the repository's automated-release dispatch
   and workflow default to `enable_direct_capture=true` in a reviewed PR. A
   one-off manual input is not rollout completion.
4. Direct-path rollback is a new build with `include_keyboard=true` and
   `enable_direct_capture=false`. Extension rollback is a new build with
   `include_keyboard=false`. Already installed builds cannot be changed
   remotely, so record the replacement build and tester assignment in #661.
