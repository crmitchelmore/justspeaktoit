# iOS Keyboard Instant Dictation

## Product decision

Just Speak uses an explicitly enabled, foreground-started **Instant Dictation**
session owned by the containing app. Once enabled, choosing the Just Speak
keyboard in a supported text field starts transcription automatically. The user
stays in the host app, sees live text in the keyboard, and taps **Stop & Insert**
to place the final transcript at the original text document's cursor.

There is no five-minute timer and no extra **Speak** tap. Readiness lasts until
the user turns it off, the app is force-quit, the phone restarts, or iOS
interrupts the audio session. After one of those events, opening Just Speak once
reconnects the persisted Instant Dictation preference.

The keyboard extension still never opens the microphone. Apple does not give
custom keyboard extensions microphone access, including with Full Access. The
containing app owns the foreground-consented audio session and stays alive with
the `audio` background mode. This is the only supported public-API route to
zero-tap recording when a keyboard appears.

Primary sources:

- [Apple custom keyboard limitations](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
- [Apple custom keyboard interface restrictions](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
- [Apple App Review Guidelines 2.5.4 and 2.5.14](https://developer.apple.com/app-store/review/guidelines/)
- [Apple AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)
- [Apple interactive intent process selection](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Wispr Flow iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- [Wispr Flow microphone session options](https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios)

## Runtime architecture

1. The user enables Instant Dictation once in Just Speak. The app requests
   microphone access and starts an `AVAudioEngine` session in the foreground.
2. The orange system microphone indicator stays visible while readiness is on.
   Idle buffers are discarded immediately on device; they are not persisted,
   transcribed, uploaded, or placed in the App Group.
3. The app refreshes an App Group heartbeat every second. The keyboard trusts
   only a heartbeat newer than four seconds, so a terminated or interrupted app
   is never presented as ready.
4. When the keyboard appears, it creates a short-lived request containing a
   nonce and `UITextDocumentProxy.documentIdentifier`, then posts a payload-free
   Darwin notification.
5. The already-running app validates the request, swaps the idle audio tap for
   the selected transcriber, and publishes throttled replacement-style interim
   text to the matching App Group record.
6. The keyboard shows that interim text but does not repeatedly edit the host
   field. This avoids duplicate words, cursor jumps, and partially committed
   replacements.
7. **Stop & Insert** finalises the recording, saves one History item, and writes
   the final transcript to the same nonce-scoped record.
8. The keyboard consumes the result only if the current document identifier
   still matches, inserts it exactly once through `textDocumentProxy`, and
   clears the shared copy. A target change cancels rather than inserting into
   the wrong app or field.
9. The app immediately returns to the discard-only readiness tap for the next
   keyboard appearance.

## Why App Intents are not the primary cold-start route

`LiveActivityIntent` can force an interactive intent to execute in the app
process, and `AudioRecordingIntent` supplies the system recording policy. They
are valuable for Action Button, Control Center, and Live Activity controls.
However, ActivityKit can reject creation of a brand-new Live Activity when the
app is fully backgrounded, and a custom keyboard still cannot itself start an
`AVAudioSession`. A cold intent therefore cannot promise a no-switch start on
every OS state. Instant Dictation keeps the consented app-owned audio session
alive instead of pretending that limitation does not exist.

## Privacy and review posture

- Enabling Instant Dictation is an explicit user action and can be ended
  immediately in the app.
- The orange microphone indicator is continuously visible while ready.
- The setup screen explains the always-ready session and discarded idle audio.
- The keyboard has no audio APIs, microphone entitlement, API keys, or access
  to the app's surrounding host text.
- The App Group contains liveness metadata, one document identifier, one nonce,
  throttled interim text, and one short-lived final result. It never contains
  audio or credentials.
- Full Access is required for the App Group and for user-selected cloud models.
- Do not use silent playback or private URL schemes to evade iOS lifecycle
  rules.

## Honest platform boundary

“Anywhere” means any normal text field that accepts third-party keyboards. iOS
uses the system keyboard for secure fields and phone-pad traits, and host apps
may reject all custom keyboards. A phone restart, force quit, system audio
interruption, microphone revocation, or process termination also requires one
foreground reconnect. The keyboard must say this directly rather than promise
impossible lifetime microphone ownership.

## Signed-device release gate

Simulator tests can prove state transitions and build integrity, but not the
background microphone or custom-keyboard lifecycle. On a real iPhone:

- Enable Instant Dictation once, return to Notes, choose Just Speak, and verify
  recording starts automatically without an app switch or a mic tap.
- Confirm live text appears in the keyboard within the selected provider's
  normal streaming latency.
- Tap **Stop & Insert** and verify one insertion at the original cursor plus one
  History item.
- Repeat in Messages, Safari, Mail, and a third-party editor without reopening
  Just Speak.
- Change apps or text documents during recording and confirm the request cancels
  without inserting into the new destination.
- Confirm the orange indicator remains present while ready and clears as soon
  as Instant Dictation is turned off.
- Confirm idle readiness creates no files, History entries, transcripts, or
  provider traffic.
- Force-quit the app and restart the phone separately; verify the keyboard asks
  for one reconnect within four seconds rather than claiming readiness.
- Test calls, Siri, alarms, route removal, Bluetooth changes, screen lock, Low
  Power Mode, microphone revocation, and loss of network for cloud models.
- Verify selection replacement, undo, Space, Backspace, cursor movement,
  cancellation, globe switching, secure fields, phone pads, iPad layouts,
  VoiceOver, and large text.

Do not call the replacement fully verified until this matrix passes in the
signed development or TestFlight build.
