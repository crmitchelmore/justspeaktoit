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
one control row (globe · language chip · mic/stop · delete · return). There is
deliberately no QWERTY layer; the globe key returns to a system keyboard for
typing. Two capture paths exist behind `KeyboardCapturePlanner`:

- **Direct** (primary): the extension records via `AVAudioEngine` and
  transcribes with Apple Speech (on-device preferred), streaming text into the
  host field through stable-prefix commit + tail replacement.
- **Handoff** (fallback): the v1 Instant Dictation flow, used when the
  extension cannot run the microphone or speech recognition.

Both paths require Full Access; without it the keyboard shows setup guidance
and creates no state.

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

State-machine, streaming-edit, planner, and language-preference logic are pure
SpeakCore types; run their tests with:

```bash
swift test --filter Keyboard
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
   state, creates no App Group state, and never claims it can record.
4. With Full Access on, verify the observed-status rows update after opening
   the keyboard once.

### Direct path: permissions (open risk — verify first)

1. Fresh install, Full Access on, no permissions granted. In Notes, open the
   Just Speak keyboard and tap the mic.
2. **Record whether iOS presents the microphone and speech-recognition
   prompts inside the keyboard.** This is the load-bearing platform
   assumption; note OS version and device.
3. Grant both → recording must start with a visible red stop state.
4. Repeat on a second install and **deny** the microphone → the keyboard must
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

### Direct path: language quick-switch

1. In the app, set a spoken language; open the keyboard → the chip shows it.
2. Tap the chip → it cycles to the next quick language in one tap (≤2 taps
   from anywhere in the keyboard). Chip is disabled while recording.
3. Dictate in the switched language and verify recognition uses it.
4. Switch the app language, reopen the keyboard → chip follows the app.

### Direct path: interruptions and target changes

1. Receive a call / trigger Siri mid-dictation → capture ends, words already
   streamed remain, no crash; mic tap starts a fresh session.
2. Switch to a different text field or app mid-dictation → capture cancels,
   already-streamed text stays in the original field, nothing streams into
   the new target.
3. Move the cursor elsewhere in the same field mid-dictation (known risk):
   record observed behaviour; tail replacements must at worst touch text near
   the new cursor, never beyond the streamed tail length.
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

- `RequestsOpenAccess` is declared for the audio session, Apple Speech, the
  App Group, and user-selected cloud transcription in the fallback path.
- The extension declares `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription`; it records only while the mic key is
  active and prefers on-device recognition.
- The keyboard does not read, persist, or transmit surrounding host text.
- The App Group contains: versioned handoff records (schema version, request
  UUID, document identifier, timestamps, phase, safe failure enum, throttled
  interim text, short-lived final transcript) and the language selection.
  Never audio or credentials.
- No private settings URL, responder-chain workaround, Apple keyboard asset,
  or unsupported containing-app launch is used.
- App Review notes should describe both capture paths, the permission grants,
  and the secure-field, phone-pad, and host-app restrictions exactly as users
  see them.
