# iOS Keyboard v2: In-Keyboard Dictation Design

> **Shipping status:** the keyboard extension is included in TestFlight by
> default, using the existing Instant Dictation handoff. Direct capture is an
> independent build policy and remains default-off until the physical-device
> matrix in [iOS keyboard verification](ios-keyboard-mvp-verification.md)
> passes. This lets the handoff-only keyboard ship without attempting
> microphone or Speech permissions inside the extension.

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

Two capture paths behind one planner (`KeyboardCapturePlanner` in SpeakCore)
and an independent direct-capture policy:

| Condition | Path |
| --- | --- |
| No Full Access (no audio session, no App Group) | **Blocked** — setup guidance in the strip |
| Full Access, direct capture disabled by policy | **Handoff** without reading/requesting extension permissions |
| Full Access, direct capture enabled, mic + speech permission not denied | **Direct**: record + transcribe inside the extension |
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

### Direct path (candidate)

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
  deletes never exceed the volatile tail. `KeyboardDocumentSession` also owns
  the leading separator and snapshots bounded context on both sides of the
  cursor after every extension-authored edit. A caret move or host edit that
  makes the replacement anchor unprovable pauses the run before another tail
  deletion. Composed clusters are deleted only while the complete context
  proves scalar-wise progress; ambiguous outcomes are never followed by an
  insert.
  Text therefore **streams into the field as the user speaks**, with the same
  live text mirrored in the keyboard strip.
- Language quick-switch chip: `KeyboardDictationPreferencesStore` (App Group)
  mirrors the app's spoken-language preference and keeps a ring of up to four
  recent languages; the chip cycles the ring in one tap (≤2 taps requirement).
- Profile/mode menu: the same store holds one schema-versioned, app-owned
  `KeyboardProfileSelection` catalogue. `Local` is explicit direct Apple Speech
  with no polish. `App` snapshots the app's exact transcription mode/model,
  language, and post-processing model with an `appHandoff` route. Both options
  are defined by `KeyboardDictationProfileCatalog` in SpeakCore, remain
  reachable in two taps, and stay available without Apple Foundation Models.
  The projection contains no credentials or custom prompt text.
- Guardrails: every engine callback carries a per-run UUID, so a delayed result,
  final, error, timeout, or interruption from a cancelled recogniser cannot
  mutate or tear down a newer run. A document/selection mutation mid-session
  cancels capture and
  commits what was already streamed (never streams into the wrong field);
  audio interruptions finish gracefully, keeping inserted words.

### Handoff path (fallback)

The v1 Instant Dictation transport is preserved behind
`KeyboardHandoffController` (extension) + `KeyboardInstantDictationCoordinator`
(app): app-owned mic session, nonce-scoped App Group records, interim
transcript mirroring, single insert on completion. Each request snapshots its
selected profile, and the app executes that exact model/language/polish
configuration or returns `profileUnavailable`; it never silently downgrades.
The keyboard also automatically degrades to this path when direct capture fails with a permission-style error.
Setup copy distinguishes the App profile from Local mode's default-off and
permission-failure handoff without implying that the rollout flag is enabled.

### Surface

One compact layout (~170 pt portrait iPhone; v1 was 300 pt):

- **Strip:** live partial transcript while dictating; state/setup copy
  otherwise; inline Cancel while capturing.
- **Control row:** globe (when required) · language chip · profile chip ·
  mic/stop · delete · return. Each chip appears only when it has somewhere to
  switch to, and the mic drops its caption while both are present so the row
  stays one line at the same height. Deliberately no QWERTY — the globe key
  returns to the system keyboard for typing, per the v1 correction-UX decision
  which stands.

## What was kept vs redone

| Piece | v2 status |
| --- | --- |
| `KeyboardHandoffStore` / records / signals (SpeakCore) | Extended with an immutable profile snapshot |
| `KeyboardInstantDictationStore` + coordinator | Extended to execute the request snapshot |
| `KeyboardLaunchPolicy` | Kept; feeds the new planner |
| `KeyboardCorrectionPlan` (safe undo) | Kept in SpeakCore; the v2 surface drops the undo/cursor row in favour of delete + re-dictation |
| `KeyboardViewController` monolith (~800 lines incl. UI) | Split: shell controller, `KeyboardViewModel`, `KeyboardRootView`, `KeyboardDictationEngine`, `KeyboardHandoffController` |
| 13-state single presentation enum | Direct machine + handoff presentation, unified in one strip |

## Privacy and review posture

- Recording happens only while the mic key is active; there is no idle
  listening in the direct path. The permanent orange indicator now exists only
  when the user explicitly enables the fallback.
- The keyboard reads bounded context immediately before and after the cursor
  locally to prove its replacement anchor. It never persists or transmits that
  host context.
- The App Group carries handoff records, language selection, and a non-secret
  profile projection. Never audio, credentials, custom prompts, or surrounding text.
- Extension Info.plist declares microphone and speech-recognition usage
  strings; both permissions are user-granted and revocable in Settings.

## Open risks (device-matrix items)

1. **Permission prompts from the extension**: iOS versions differ in whether
   `AVAudioApplication.requestRecordPermission` presents UI inside a keyboard.
   If a device declines, the engine reports failure and the keyboard degrades
   to handoff — but the prompt flow must be confirmed on hardware.
2. **Memory ceiling** under long dictation with on-device speech.
3. **Cursor/host mutations mid-dictation**: code now pauses when the bounded
   before/after context no longer matches the session anchor. Device testing
   must confirm callback ordering across Notes, WhatsApp, and Safari.
4. **`SFSpeechRecognizer` availability inside extensions** per locale asset
   state (undownloaded on-device models fall back to server dictation).
