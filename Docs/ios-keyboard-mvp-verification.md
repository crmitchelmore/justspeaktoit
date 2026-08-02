# iOS Custom Keyboard MVP Verification

For the always-ready background-microphone architecture and its additional
device matrix, also follow [iOS Keyboard Instant Dictation](ios-keyboard-instant-dictation.md).

## Scope and architecture

The Just Speak keyboard is intentionally transcription-first. It does not
implement autocorrection or attempt an Apple-keyboard clone. It provides a
small correction row (safe undo, cursor movement, space, and backspace), and a
selected range can be replaced by the next voice transcription. The globe
control uses `UIInputViewController.handleInputModeList(from:with:)` so a user
can return to a system keyboard for full typing.

Apple does not allow a custom keyboard extension to access the microphone. The
primary Instant Dictation handoff is therefore:

1. The user explicitly enables Instant Dictation once in Just Speak. The app
   keeps a recording-capable audio session ready until the user turns it off or
   iOS interrupts/terminates it. Idle buffers are discarded locally while the
   system microphone indicator remains visible.
2. Opening the keyboard starts automatically by creating a short-lived,
   nonce-scoped request bound to `UITextDocumentProxy.documentIdentifier` in
   `group.com.justspeaktoit.ios`, then posts a payload-free Darwin notification.
3. The already-running containing app validates the nonce and records through
   the existing
   `TranscriptionRecordingService` using the selected local or remote model.
4. Throttled interim text appears inside the keyboard. The user finishes from
   the keyboard; the app saves the completed transcript to History and writes one temporary
   final transcript to the matching versioned App Group record.
5. The keyboard inserts the matching result with
   `textDocumentProxy.insertText` and deletes the App Group copy. History
   remains available in Just Speak.

If the containing app has been force-quit, interrupted, terminated, or the
phone restarted, the heartbeat becomes stale and the keyboard asks the user to
open Just Speak once to reconnect. Custom keyboard extensions are not one of the iOS
extension points for which Apple documents `NSExtensionContext.open` support,
so the keyboard must not claim it can cold-launch the containing app.

Requests expire after three minutes, transcription finalisation after 90
seconds, and completed App Group results after 60 seconds. A mismatched nonce or
document identifier can neither read nor clear another request. Keyboard-originated
dictation does not write to the clipboard; its nonce-scoped interim text is
replacement-only and expires with the request. Temporary batch audio is deleted
after transcription.

## Correction UX decision

Do not build a full QWERTY keyboard until product evidence justifies owning the
complete typing experience. Apple requires custom keyboards to handle field
traits, compact and regular widths, rotation, iPad layouts, input-mode
switching, text context, and accessibility. Wispr Flow's public iOS notes also
show the ongoing surface area of a production QWERTY keyboard: capitalization,
autocorrect, shift/caps lock, double-space punctuation, multi-touch ordering,
hit targets between keys, and language behavior.

The supported Just Speak correction path is deliberately smaller:

- select mistaken host-app text and choose **Replace Selection by Voice**;
- undo the most recent insertion only when the exact inserted suffix still
  precedes the cursor;
- move the cursor, insert a space, or delete backward without changing
  keyboards;
- use the globe key for arbitrary character typing with Apple's keyboard.

Primary references:

- [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)
- [Handling text interactions in custom keyboards](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)
- [`NSExtensionContext.open`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:))
- [Wispr Flow iPhone keyboard notes](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)

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

The old containing-app capture screen and `justspeaktoit://keyboard` deep link
have been removed. A simulator run must not navigate away from the host text
field to service a keyboard request. The nonce, transcript, API keys, and
surrounding text must not appear in logs.

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
5. Open Just Speak once, enable Instant Dictation, then return to the focused
   Notes field and choose the Just Speak keyboard.
6. Confirm recording starts automatically while Notes remains visible and live
   words appear in the keyboard without touching the host field.
7. Speak, tap **Stop & Insert** in the keyboard, and confirm the matching
   text is inserted once at the cursor or over the current selection without an
   app switch.
8. Confirm the completed transcript is present in Just Speak History while the
   temporary App Group result cannot be inserted again.
9. Select a word in Notes, choose **Replace Selection by Voice**, complete a
   second handoff, and confirm the selected word is replaced.
10. Verify safe undo succeeds immediately after insertion but refuses to delete
    text if the cursor moved or the host text changed.

After the containing app is force-quit, interrupted, terminated, or the phone
restarts, confirm the keyboard truthfully asks the user to open Just Speak once
to reconnect.

### Cloud-model happy path

Repeat the happy path with a configured remote streaming model and then a
remote batch model. Confirm:

- the resulting History item identifies the selected model;
- missing credentials or network failures produce a generic safe error;
- no API key, provider response body, transcript, nonce, or surrounding text is
  emitted to device logs;
- batch audio is removed after success and after cancellation/failure;
- the temporary result is inserted once and expires if the user waits over 60
  seconds before returning; the History entry remains.

### Cancellation and recovery

1. Cancel from the keyboard before completing the handoff. Confirm nothing is
   inserted and a newer request still works.
2. Switch away from the keyboard while recording. Confirm recording stops,
   temporary state is cleared, and returning to the keyboard starts a fresh request.
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
- Only a schema version, request UUID, document identifier, timestamps, phase,
  safe failure enum, throttled interim text, and final transcript are shared.
  App Group text is removed on insertion, cancellation, or timeout; the
  containing app's History record is not.
- No private settings URL, responder-chain URL workaround, Apple keyboard asset,
  copied Apple keyboard layout, or unsupported containing-app launch is used.
- App Review notes should describe the one-time enable/reconnect boundary and
  the secure-field, phone-pad, and host-app restrictions exactly as users see them.
