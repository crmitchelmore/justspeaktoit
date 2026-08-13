# iOS Custom Keyboard v2 Verification

The keyboard is an internal, off-by-default feature. Generate with
`TUIST_IOS_KEYBOARD=1 tuist generate` before running this matrix. A normal
project generation or TestFlight release must omit `JustSpeakKeyboard.appex`
(CI generates with the flag so the extension keeps compiling, but release
workflows stay gated behind the manual `include_keyboard` input).

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

- **Direct** (primary): the extension records via `AVAudioEngine` and
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

`SpeakiOSTests` and `SpeakiOSUITests` are the only generated Tuist test targets
(sourced from `Tests/SpeakiOSTests/**` and `Tests/SpeakiOSUITests/**`), so they
do not contain the new keyboard suites. State-machine, streaming-edit, planner,
and language-preference logic are pure SpeakCore types, and the keyboard
distribution guards live in `Tests/SpeakAppTests`; run both through SwiftPM:

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

## Physical-device matrix (release gate)

Use a development or TestFlight build signed with App Group
`group.com.justspeaktoit.ios` for the app and keyboard extension. The
TestFlight workflow needs a provisioning profile for bundle ID
`com.justspeaktoit.ios.keyboard`, stored as GitHub secret
`IOS_KEYBOARD_APPSTORE_PROFILE`.

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

1. Fresh install, Full Access on, no permissions granted. In Notes, open the
   Just Speak keyboard and tap the mic.
2. **Record whether iOS presents the microphone and speech-recognition
   prompts inside the keyboard.** This is the load-bearing platform
   assumption; note OS version and device.
3. Grant both → recording must start with a visible red stop state.
4. With Instant Dictation enabled in the app (Settings › Set Up Keyboard),
   repeat on a second install and **deny** the microphone → the keyboard must
   surface the failure and degrade to the Instant Dictation fallback without
   hanging.
5. Revoke permissions in Settings afterwards and confirm the keyboard plans
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
4. Switch the app language, reopen the keyboard → chip follows the app.

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
3. Stop or cancel dictation **before** moving the cursor elsewhere in the same
   field: the streamer's tail bound only holds while the selection stays where
   it left it. Then assert that unrelated text in the field is unchanged.
   Moving the cursor mid-dictation is a known risk — if you do it, record the
   observed behaviour; edits must at worst touch text within the streamed tail
   length of the new cursor, never beyond it.
4. Dismiss the keyboard mid-dictation → audio session releases (no stuck
   orange indicator).

### Direct path: memory

With the Xcode memory gauge attached to the extension, dictate continuously
for 2+ minutes with on-device speech. The extension must stay comfortably
under the keyboard budget (~60–80 MB) and must not be jetsammed.

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
  Full Access. The extension declares `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription`, and the user must authorise both.
  Whether iOS presents those prompts to a keyboard extension — and honours the
  grants — is the unverified platform assumption tracked in "Direct path:
  permissions" above; the handoff path covers devices that refuse.
- The extension records only while the mic key is active and prefers on-device
  recognition.
- `Local` sends no transcript to an app or network post-processor. `App`
  explicitly routes the selected model through the containing app; credentials
  stay in Keychain and never enter the App Group.
- The keyboard does not read, persist, or transmit surrounding host text.
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
