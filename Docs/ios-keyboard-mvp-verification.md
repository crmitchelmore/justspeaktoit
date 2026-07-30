# iOS Custom Keyboard MVP Verification

## Scope and architecture

The Just Speak keyboard is intentionally transcription-first. It does not
implement ordinary typing, autocorrection, or an Apple-keyboard clone. The
globe control uses `UIInputViewController.handleInputModeList(from:with:)` so a
user can return to a system keyboard for typing.

Apple does not allow a custom keyboard extension to access the microphone. The
supported handoff is therefore:

1. The keyboard creates a short-lived, nonce-scoped request in
   `group.com.justspeaktoit.ios`.
2. The keyboard opens `justspeaktoit://keyboard?request=<uuid>` through its
   extension context.
3. The containing app validates the nonce and records through the existing
   `TranscriptionRecordingService` using the selected local or remote model.
4. The app writes one final transcript to the matching versioned record.
5. After the user returns to the originating app, the keyboard inserts the
   matching result with `textDocumentProxy.insertText` and deletes it.

Requests expire after three minutes, transcription finalisation after 90
seconds, and completed results after 60 seconds. A mismatched nonce can neither
read nor clear another request. Keyboard-originated dictation does not write to
History or the clipboard, does not publish partial text through the legacy App
Group keys, and deletes temporary batch audio after transcription.

## Simulator verification

Run from a generated workspace on a booted iOS Simulator:

```bash
tuist generate --no-open
xcodebuild test \
  -workspace "Just Speak to It.xcworkspace" \
  -scheme SpeakiOS \
  -destination "platform=iOS Simulator,id=<BOOTED_UDID>" \
  -only-testing:SpeakiOSTests \
  -only-testing:SpeakiOSUITests
```

Verify the installed app contains both extensions:

```bash
find "<JustSpeakToIt.app>/PlugIns" -maxdepth 1 -type d -name '*.appex' -print
```

Expected entries are `JustSpeakKeyboard.appex` and
`JustSpeakToItWidgetExtension.appex`. Simulator keyboard enablement can vary by
runtime. When the system permits it, open Settings and follow General ›
Keyboard › Keyboards › Add New Keyboard, then select Just Speak. Do not modify
Simulator preference files directly.

For a deterministic containing-app capture screen, launch the Debug app with:

```text
--keyboard-handoff-demo
JUSTSPEAKTOIT_SIMULATOR_TRANSCRIPT=Simulator keyboard result
```

Tap **Finish & Transcribe** and confirm the screen reaches **Ready to Insert**.
The nonce, transcript, API keys, and surrounding text must not appear in logs.

## Physical-device matrix

Use a development or TestFlight build signed with App Group
`group.com.justspeaktoit.ios` for the app and keyboard extension. The TestFlight
workflow also needs a provisioning profile for bundle ID
`com.justspeaktoit.ios.keyboard`, stored as GitHub secret
`IOS_KEYBOARD_APPSTORE_PROFILE`.

### Enablement and Full Access

1. Launch Just Speak once and open Settings › Set Up Keyboard.
2. Tap **Open iOS Settings**.
3. Go to General › Keyboard › Keyboards › Add New Keyboard › Just Speak.
4. Open Just Speak in the keyboard list and enable **Allow Full Access**.
5. Return to Just Speak. The observed status updates after the extension has
   actually been opened; iOS does not expose a complete enabled-keyboard query
   to containing apps.
6. Turn Full Access off and verify the keyboard shows the explanatory blocked
   state and does not open the app or create a request.

The Full Access explanation must remain explicit: it enables the shared App
Group handoff and any network use required by the user's chosen cloud model. It
does not grant microphone access to the keyboard, and the keyboard does not
inspect or transmit surrounding text.

### Local/offline happy path

1. In Just Speak, select Local and an installed Apple Speech model.
2. Disable network connectivity.
3. Open Notes or another standard text editor and focus a normal text field.
4. Hold the globe key and choose Just Speak.
5. Tap **Speak in Just Speak**. Confirm the containing app opens and requests
   microphone/speech permission only there.
6. Speak, tap **Finish & Transcribe**, and wait for **Ready to Insert**.
7. Return to Notes using the app switcher or Back gesture where available,
   choose Just Speak again if iOS changed keyboards, and confirm the text is
   inserted once at the cursor or over the current selection.
8. Reopen the keyboard and confirm the result is not inserted again.

iOS does not provide a public API that returns an extension directly to the
originating third-party app, so the UI truthfully asks the user to return.

### Cloud-model happy path

Repeat the happy path with a configured remote streaming model and then a
remote batch model. Confirm:

- the selected model name appears in the capture screen;
- missing credentials or network failures produce a generic safe error;
- no API key, provider response body, transcript, nonce, or surrounding text is
  emitted to device logs;
- batch audio is removed after success and after cancellation/failure;
- the final result is inserted once and expires if the user waits over 60
  seconds before returning.

### Cancellation and recovery

1. Cancel from the keyboard before completing the handoff. Confirm nothing is
   inserted and a newer request still works.
2. Cancel while recording in the app. Confirm recording stops, partial audio is
   deleted, and the keyboard reports cancellation.
3. Leave the flow open beyond its timeout. Confirm a timeout state, no
   insertion, and a successful retry with a fresh nonce.
4. Force-quit Just Speak during recording and confirm a retry does not consume
   stale state.
5. Start an ordinary Just Speak recording first, then trigger the keyboard.
   Confirm the keyboard request reports recording unavailable without taking
   over the existing session.

### System limitations

Confirm Just Speak is absent and the system keyboard remains active in:

- secure/password fields;
- phone-pad fields;
- an app known to disable third-party keyboards.

Also verify portrait and landscape on iPhone, split/full-width layouts on iPad,
light and dark appearance, large Accessibility text sizes, VoiceOver focus and
labels, Switch Control targets, and touch targets of at least 44 points.

## App Review and privacy evidence

- `RequestsOpenAccess` is declared because the extension uses an App Group and
  may hand off to user-selected cloud transcription in the containing app.
- The extension contains no microphone permission or audio APIs.
- The containing app's existing microphone and speech usage descriptions apply
  when capture begins.
- Only a schema version, request UUID, timestamps, phase, safe failure enum, and
  final transcript are shared. The final transcript is removed on insertion or
  timeout.
- No private settings URL, responder-chain URL workaround, Apple keyboard asset,
  or copied Apple keyboard layout is used.
- App Review notes should describe the manual return-to-origin step and the
  secure-field, phone-pad, and host-app restrictions exactly as users see them.
