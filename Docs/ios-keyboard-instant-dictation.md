# iOS Keyboard Instant Dictation

> **Shipping status:** the keyboard is included in TestFlight and Instant
> Dictation is its default capture path. Direct extension capture remains an
> independent, default-off candidate — see
> [iOS Keyboard v2 design](ios-keyboard-v2-design.md). Normal automated builds
> use `include_keyboard=true` and `enable_direct_capture=false`, so the
> extension does not read or request microphone/Speech permissions. It reads
> bounded context immediately before and after the cursor locally to prove its
> replacement anchor, but never persists or transmits that host context.

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

In this handoff path the keyboard extension never opens the microphone: the
containing app owns the foreground-consented audio session and stays alive with
the `audio` background mode. (The v2 candidate path *attempts* to record inside
the extension with Full Access plus user-granted microphone and speech
permissions; that capability is an unverified platform assumption, and this
handoff exists precisely for devices and users where it is refused or
unavailable.)
App-owned capture remains the only route to zero-tap recording the moment the
keyboard appears, since the extension cannot start its session before the user
interacts.

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
   still matches, inserts it through `textDocumentProxy`, then clears the
   shared copy. A target change cancels rather than inserting into
   the wrong app or field. After **Stop & Insert**, dismissing the keyboard or
   switching keyboards lets finalisation continue. No text is inserted while
   the keyboard is inactive; returning to the matching document consumes the
   still-valid result at its current caret. Moving the caret within that
   document does not cancel app-owned handoff. Dismissal before Stop still
   cancels capture. Existing nonce, document and expiry checks remain in force.
   Insertion and clearing are not atomic: if the extension terminates after
   the proxy accepts the text but before the shared copy is cleared, returning
   to the matching document can insert it again. The retained result permits
   recovery, but does not guarantee exactly-once delivery across termination.
9. The app immediately returns to the discard-only readiness tap for the next
   keyboard appearance.

## Delivery from outside the keyboard (issues #1002, #1003, #1005)

A dictation that did not start in the keyboard can still finish in the field.
Three App Group keys carry it, each with exactly one writing process, as with
the hand-off itself:

| Key | Writer | Contents |
|---|---|---|
| `keyboardDelivery.target.v1` | keyboard extension | which document is open, and for how long |
| `keyboardDelivery.offer.v1` | containing app | one completed transcript awaiting delivery |
| `keyboardDelivery.claim.v1` | keyboard extension | the offer it inserted or dismissed |

1. While it is on screen the keyboard advertises its current
   `documentIdentifier`. The advertisement lapses after 8 seconds unless it is
   refreshed, because `viewDidDisappear` is not guaranteed to run before the
   extension is suspended or killed. A secure field is never advertised.
2. A hardware trigger (Action Button, Siri, Shortcuts) checks the hand-off
   first. A keyboard-owned dictation that is recording, finishing or
   transcribing is **finished** by the press, so the transcript lands in the
   field the keyboard opened it for — instead of the old collision, where the
   press either refused with "already recording" or stopped into the hardware
   destination. A request that has not begun recording is left alone.
3. Every completed capture then leaves an offer. With a fresh target it is a
   `targetedInsert`, valid for 60 seconds and bound to that exact document; it
   auto-inserts there and **nowhere else** — a different field gets nothing,
   not even a chip. Otherwise it is a `latePickup`, valid for 10 minutes,
   offered as a one-tap chip in the keyboard strip. Watch imports publish one
   too.
4. `latePickup` auto-insertion is off by default and, when enabled, still
   requires the current document to be the exact one the capture started in.
   Nothing else ever inserts without a tap.
5. Insertion happens before the claim is written, so a death in between leaves
   the offer retryable rather than losing the transcript — the same trade the
   hand-off consumer makes, and with the same exactly-once caveat.
6. After any insertion the keyboard calls `advanceToNextInputMode()` **only**
   when exactly two keyboards are enabled. iOS offers "next", never "previous",
   and with three or more that would land the user somewhere they did not
   choose. The setup screen shows the count and says why hand-back is off.

None of this changes where a transcript otherwise goes: the clipboard, the
History entry, and the Live Activity are untouched, so an expired or missed
offer costs the user nothing they had before. Everything here lives behind Full
Access — without it the App Group is unavailable, no target is advertised, no
offer is readable, and hardware triggers behave exactly as they do today.

## Both directions are pushed, not polled (issue #990)

There are two payload-free Darwin notifications, one per direction. Neither
carries data — Darwin notifications cannot — so both are only "look again,
now"; the command, the nonce, the phase and the text still cross in the App
Group and are still validated there.

| Notification | Posted by | On | Read by |
|---|---|---|---|
| `…keyboardHandoff.requestChanged` | keyboard extension | create, finish, cancel | the app's `KeyboardInstantDictationCoordinator` |
| `…keyboardHandoff.statusChanged` | containing app | every app-owned write: phase transition, interim update, new pickup offer | the keyboard's hand-off controller and delivery loop |

The keyboard used to learn about a phase change or a new interim only on its
next poll tick: 120 ms while a request was in flight, 500 ms otherwise. It now
reads the record the moment the app says it changed, and **polling stays purely
as a safety net at 500 ms** — one cadence, no in-flight tier. The tighter tier
existed only to shorten that wait, and cost the extension a wake-up eight times
a second inside a hard memory and CPU budget; a dropped notification now costs
at most one 500 ms tick instead of losing the update.

The app-side interim throttle is deliberately **unchanged at 120 ms**. It is
already faster than transcription providers emit partials, so tightening it
would double the extension wake-ups and the host-app text mutations without
producing an update there was anything new to show. Separately, an interim no
longer rewrites the status expiry on every tick: the rewrite is skipped while
more than two minutes of the three-minute lifetime remain, so a long dictation
still cannot time out mid-sentence but a burst of partials writes one key
instead of two.

## Words in the field while you speak (issue #1004)

With **Show words while you speak** on (the default), the keyboard streams each
interim into the host field as *marked* text — the provisional, underlined text
Apple dictation and CJK input methods use — via
`UITextDocumentProxy.setMarkedText(_:selectedRange:)`, and commits it with
`unmarkText()` when the transcript is final. The user sees words from the first
partial instead of a strip that fills while the field stays empty.

Marked text sits in the user's document, so the governing rule is that it is
never left behind. Every decision lives in `KeyboardMarkedTextSession`, a pure
value type in SpeakCore, and the extension is a thin `switch` over the actions
it returns — which is why the abandonment paths are proved by `swift test`
rather than argued about:

| Ending | Action |
|---|---|
| transcript is ready | `setMarkedText(final)` + `unmarkText()` — committed in place |
| cancelled, failed, timed out | `setMarkedText("")` + `unmarkText()` — removed |
| keyboard dismissed | same, on `deactivate()`, before the proxy callbacks are released |
| document changed | same, and streaming stops for the rest of the run |
| caret moved by the user | same, and streaming stops for the rest of the run |

Every one of those is idempotent, so a double dismissal, or a completed record
read again on the next tick, does nothing the second time. Once a session has
abandoned streaming it never resumes it: the run finishes with the ordinary
single insertion, which is exactly what #1030 guarantees still arrives after a
dismissal or a caret move. Exactly one of "finalise" and "plain insert" ever
happens for a given transcript, so the words can be neither doubled nor lost.

A **secure field is never marked into**, whatever the preference says — the
session is created disabled — matching the rule that a secure field is never a
delivery target either. A `setMarkedText` of the keyboard's own makes the host
report a selection change; at most one such echo is swallowed per write, so a
genuine caret move still abandons the stream, and a host that reports more than
one only makes the keyboard fall back to plain insertion. It cannot make it
insert in the wrong place.

What no host test can settle is how individual apps treat marked text. The
preference exists for that: with it off, behaviour is exactly what it was
before the feature — one insertion at the end.

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
- After Stop, dismiss or globe-switch during finalisation; verify no insertion
  while inactive, one History item, and one insertion on return to the same
  document. Repeat during provider drain and post-processing.
- Move the caret within the same document before and after Stop; verify the
  final text inserts once at the current caret. Switch to another field during
  finalisation and confirm it never receives the old transcript.
- Repeat in Messages, WhatsApp, Safari, Mail, and a third-party editor without reopening
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
