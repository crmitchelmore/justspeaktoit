# iOS Keyboard v2: In-Keyboard Dictation Design

> **Shipping status:** disabled. Default local, archive, and TestFlight builds
> omit the extension. Internal CI generates with `TUIST_IOS_KEYBOARD=1` so the
> extension keeps compiling; a manual TestFlight run additionally requires the
> off-by-default `include_keyboard` input. The physical-device matrix in
> [iOS keyboard verification](ios-keyboard-mvp-verification.md) is the release
> gate.

## Audit: why v1 bounced to the main app

Keyboard v1 (PRs #567–#569) assumed the archived App Extension Programming
Guide's statement that a custom keyboard "cannot access the device microphone",
and therefore built everything around an app-owned recorder:

1. The containing app keeps an always-on `AVAudioEngine` "Instant Dictation"
   session alive (orange indicator permanently visible while enabled).
2. The keyboard writes nonce-scoped commands into the App Group and the app
   records, transcribes, and posts results back.

That architecture worked, but its costs were structural, not cosmetic:

- **Setup friction:** enable keyboard + Full Access + a third in-app step
  ("Enable Instant Dictation once"), plus a reconnect trip to the app after
  every force quit, restart, or audio interruption.
- **Permanent orange mic indicator** while ready — a hard sell for a keyboard
  users keep enabled all day.
- **Fragility:** heartbeat staleness, request expiry, and Darwin-notification
  wakeups added many failure states (the v1 controller surfaced 13).
- **A 300 pt keyboard** dominated by status copy rather than a compact strip.

The premise itself is worth retesting, but the replacement capability is not a
documented one. Competing dictation keyboards (Wispr Flow, Superwhisper,
Spokenly) record without an app switch, which indicates that a keyboard
extension with `RequestsOpenAccess` and user-granted Full Access **can** in
practice activate an audio session and use the Speech framework. Apple
documents Full Access as gating shared containers and network access, not
microphone capture, and does not state that extensions may record; the
extension must separately declare `NSMicrophoneUsageDescription`/
`NSSpeechRecognitionUsageDescription` and the user must grant both. **Treat
in-extension capture as an unverified platform assumption** until the
physical-device matrix signs it off: first-run permission behaviour on real
devices is a mandatory verification item, and the architecture keeps a full
fallback for devices that refuse.

## Decision

Two capture paths behind one planner (`KeyboardCapturePlanner` in SpeakCore):

| Condition | Path |
| --- | --- |
| No Full Access (no audio session, no App Group) | **Blocked** — setup guidance in the strip |
| Full Access, mic + speech permission not denied | **Direct**: record + transcribe inside the extension |
| Full Access, mic or speech denied / recognizer missing / capture fails | **Handoff**: v1 Instant Dictation flow |

Note: issue #610 sketched "handoff when Full Access is off", but Full Access
also gates the App Group container, so the handoff cannot run without it
either. The fallback tier therefore keys on *microphone/speech availability in
the extension*, with Full Access a hard requirement for both paths.

The **Direct** row is conditional, not a guarantee: the planner only *attempts*
direct capture when nothing is known to block it. Extension microphone and
Speech support is unverified on device (see above), so any denied prompt,
missing recogniser, or capture failure degrades to **Handoff** at runtime
(`fallBackToHandoffIfDirectCaptureIsImpossible`).

### Direct path (primary)

- `KeyboardDictationEngine` (extension-only): `AVAudioEngine` input tap →
  `SFSpeechAudioBufferRecognitionRequest` with partial results.
  `requiresOnDeviceRecognition` is set whenever the locale supports it, so
  dictation is on-device and offline-capable by default; other locales use
  Apple's server dictation (network is covered by Full Access).
- **Memory:** keyboard extensions get roughly a 60–80 MB ceiling. Apple Speech
  runs out of process (XPC to `com.apple.speech.localspeechrecognition` /
  server relay), so the extension holds only the audio engine, tap buffers
  (2048 frames), and SwiftUI surface. No model weights, no SpeakCore
  networking clients, are loaded in the extension. Measuring the real
  footprint on device is part of the verification matrix.
- `KeyboardDictationMachine` (SpeakCore, pure): mic-tap toggle state machine
  producing effects (`startCapture`, `stopCapture`, `cancelCapture`,
  `applyEdit`). Fully unit-tested.
- `KeyboardTranscriptStreamer` (SpeakCore, pure): **stable-prefix commit +
  tail replacement.** Each partial hypothesis becomes a minimal edit
  (`deleteCount` + `insertion`) against the document proxy. Words that survive
  one revision are committed at word boundaries and never rewritten; the final
  two words stay volatile (engines revise those most). Structural invariant:
  deletes never exceed the volatile tail, so **while the selection stays where
  the streamer left it** host-app text is never eaten. If the user moves the
  cursor mid-dictation the tail no longer maps to the streamed text, so the
  verification matrix requires stopping dictation before editing elsewhere in
  the same field and records observed behaviour when it is not.
  Text therefore **streams into the field as the user speaks**, with the same
  live text mirrored in the keyboard strip.
- Language quick-switch chip: `KeyboardDictationPreferencesStore` (App Group)
  mirrors the app's spoken-language preference and keeps a ring of up to four
  recent languages; the chip cycles the ring in one tap (≤2 taps requirement).
- Guardrails: a `documentIdentifier` change mid-session cancels capture and
  commits what was already streamed (never streams into the wrong field);
  audio interruptions finish gracefully, keeping inserted words.

### Handoff path (fallback)

The v1 Instant Dictation flow is preserved verbatim behind
`KeyboardHandoffController` (extension) + `KeyboardInstantDictationCoordinator`
(app): app-owned mic session, nonce-scoped App Group records, interim
transcript mirroring, single insert on completion. The keyboard automatically
degrades to this path when direct capture fails with a permission-style error.
Setup copy now frames Instant Dictation as the fallback, not the primary flow.

### Surface

One compact layout (~170 pt portrait iPhone; v1 was 300 pt):

- **Strip:** live partial transcript while dictating; state/setup copy
  otherwise; inline Cancel while capturing.
- **Control row:** globe (when required) · language chip · mic/stop ·
  delete · return. Deliberately no QWERTY — the globe key returns to the
  system keyboard for typing, per the v1 correction-UX decision which stands.

## What was kept vs redone

| Piece | v2 status |
| --- | --- |
| `KeyboardHandoffStore` / records / signals (SpeakCore) | Kept unchanged (fallback transport) |
| `KeyboardInstantDictationStore` + coordinator | Kept unchanged (fallback capture) |
| `KeyboardLaunchPolicy` | Kept; feeds the new planner |
| `KeyboardCorrectionPlan` (safe undo) | Kept in SpeakCore; the v2 surface drops the undo/cursor row in favour of delete + re-dictation |
| `KeyboardViewController` monolith (~800 lines incl. UI) | Split: shell controller, `KeyboardViewModel`, `KeyboardRootView`, `KeyboardDictationEngine`, `KeyboardHandoffController` |
| 13-state single presentation enum | Direct machine (6 states) + handoff presentation (10), unified in one strip |

## Privacy and review posture

- Recording happens only while the mic key is active; there is no idle
  listening in the direct path. The permanent orange indicator now exists only
  when the user explicitly enables the fallback.
- The keyboard still never reads or transmits surrounding host text; edits go
  one way through `textDocumentProxy`.
- The App Group carries: handoff records (unchanged from v1) and the language
  selection. Never audio, never credentials.
- Extension Info.plist declares microphone and speech-recognition usage
  strings; both permissions are user-granted and revocable in Settings.

## Open risks (device-matrix items)

1. **Permission prompts from the extension**: iOS versions differ in whether
   `AVAudioApplication.requestRecordPermission` presents UI inside a keyboard.
   If a device declines, the engine reports failure and the keyboard degrades
   to handoff — but the prompt flow must be confirmed on hardware.
2. **Memory ceiling** under long dictation with on-device speech.
3. **Cursor moves mid-dictation**: `selectionDidChange` is unreliable in
   keyboard extensions; a user tapping elsewhere in the same field during
   dictation can misplace tail replacements. Document-change cancellation
   covers the cross-field case; same-field cursor taps need device testing.
4. **`SFSpeechRecognizer` availability inside extensions** per locale asset
   state (undownloaded on-device models fall back to server dictation).
