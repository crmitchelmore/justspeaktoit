# iOS Keyboard Quick Dictation

## Decision

Just Speak uses a foreground-started, five-minute **Quick Dictation** session in
the containing app. While that session is alive, the keyboard can start and
finish transcription without leaving the current text field.

The keyboard extension does not and cannot own microphone capture. Apple states
that custom keyboards have no device-microphone access. A fully cold keyboard
therefore cannot start recording after iOS has suspended or terminated the
containing app.

This is the same product boundary visible in Wispr Flow's public documentation:
its iOS experience has a time-limited background session (five minutes by
default), and its keyboard may need to take the user to the app when that session
is no longer available.

Sources:

- [Apple Custom Keyboard Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
- [Apple App Review Guidelines 2.5.14 and 4.4.1](https://developer.apple.com/app-store/review/guidelines/)
- [Apple App Groups](https://developer.apple.com/documentation/Xcode/configuring-app-groups)
- [Apple background recording category guidance](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)
- [Wispr Flow iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- [Wispr Flow audio-device and session timeout](https://docs.wisprflow.ai/articles/8884408990-connect-and-set-up-external-audio-devices)

## Architecture

1. The user explicitly enables Quick Dictation from Just Speak's keyboard
   settings. This starts microphone permission and audio from the foreground.
2. The containing app keeps a bounded recording-capable audio session alive.
   Idle buffers are discarded immediately on device; they are never saved,
   transcribed, transmitted, or placed in the App Group.
3. The App Group holds only a short liveness heartbeat plus the existing
   nonce-scoped handoff record.
4. Tapping **Speak** creates a request and posts a payload-free Darwin
   notification. The live containing app validates the nonce and starts the
   selected transcriber.
5. Tapping **Finish & Transcribe** changes the nonce-scoped request to
   `finishRequested`. The containing app stops, saves to History, and writes the
   final result to the short-lived handoff record.
6. The keyboard consumes that exact result once and inserts it through
   `textDocumentProxy`.
7. A fresh heartbeat is required. If iOS kills the app, an interruption ends the
   audio engine, or the five-minute window expires, the keyboard stops promising
   inline recording and tells the user to prepare a new session.

## Privacy and review posture

- Starting the ready window is an explicit user action.
- The system orange microphone indicator remains visible for the ready window.
- The setup screen explains that idle audio is discarded locally.
- The window is bounded and has an immediate **End Quick Dictation** action.
- No surrounding host-app text is read or shared.
- Full Access is still required for the App Group/networked keyboard path, but
  correction controls and the globe key remain functional without transcription.
- Do not add silent playback solely to evade suspension. The app's background
  audio use is the user-requested microphone/dictation feature itself.

## Physical-device release gate

Run these cases on a real iPhone; Simulator cannot prove extension selection or
background microphone behavior:

- Start Quick Dictation in Just Speak, return to Notes, and confirm **Speak**
  reaches **Recording** without changing apps.
- Finish from the keyboard and confirm one insertion plus one History item.
- Repeat in Safari and Messages during the same five-minute window.
- Confirm the orange microphone indicator is present for the ready window and
  clears immediately after **End Quick Dictation** or expiry.
- Confirm idle audio produces no files, History items, provider traffic, or
  transcripts.
- Force-quit Just Speak and confirm the keyboard reports that preparation is
  required within the heartbeat timeout.
- Test expiry while idle and while actively recording. Active recording may
  finish; readiness must not restart after the expired recording completes.
- Test phone call, Siri, route removal, Bluetooth changes, screen lock, Low Power
  Mode, and microphone permission revocation.
- Test selection replacement, safe undo, Space, Backspace, cursor movement,
  secure fields, cancellation, and globe-key switching.

Do not describe the feature as fully verified until this matrix passes in the
signed/TestFlight build.
