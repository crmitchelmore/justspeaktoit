# Core dictation journey regression gate

Run the required contract gate with the Apple Swift toolchain on macOS:

```sh
scripts/run-core-journey-e2e.sh
```

It has an eight-minute test-command budget and CI has a ten-minute wall-clock
timeout. It uses in-memory HTTP/stream events, temporary history storage, and
isolated defaults and pasteboards. Automation tests exchange real frames over
an owner-only UNIX socket, with a stub command handler. No microphone, provider
network, API key, or paid service is required.

The suite manifest lives in `scripts/run-core-journey-e2e.py`. Every required
suite must execute at least one passing XCTest case; a missing, renamed,
all-skipped, or partially skipped suite fails the gate even when `swift test`
exits successfully. Any test-command failure remains a failure. The runner
retains `test.log`, `timing.txt`, and `result.json` in
`.artifacts/core-journey-e2e/` on success, failure, or timeout; CI uploads them.
Timeouts terminate the entire test process group, including compiler/test
children. `result.json` records the required suites, execution counts on a
successful test-command exit, command and runner elapsed times, and gate errors.
Log replay and artifact writing do not count toward the test-command budget.
Artifact write failures are reported without replacing a failed command's exit
status; they fail an otherwise successful gate.

## Covered contracts

| Boundary | Required XCTest suites | Evidence and limits |
| --- | --- | --- |
| Hotkey gesture state | `GestureDetectorTests` | Balanced down/up, reset, bounce, cancellation; injected key events, no physical key synthesis. |
| Batch provider | `OpenAITranscriptionProviderTests`, `OpenAITranscriptionProviderErrorTests`, `MissingLiveAPIKeyAlertTests` | Real request construction and response decoding with HTTP fixtures; routing and missing/rejected-key descriptions. |
| Streaming provider | `StreamingClientContractTests` | Provider event parsing and complete transcript finalisation with injected stream events. |
| Processing | `PostProcessingManagerTests` | Empty input, local rules, cloud client stub, prompt payload; does not exercise MainManager's enabled/disabled routing. |
| Streaming delivery | `LiveTextInserterStreamingTests` | Actual inserter with an in-memory AX field contract; partial replacement, duplication and fallback decisions. |
| Clipboard and target policy | `TextOutputTests`, `ClipboardFieldIdentityPolicyTests` | Isolated pasteboard, empty text preservation, target identity and changed-field warnings; no assertion of native editor delivery. |
| Automation transport | `AutomationServerTests`, `AutomationDeadlineTests` | Real listener, framing, shipped client, owner permissions, idempotent retries, deadlines, failure followed by recovery; command execution is stubbed. |
| Recording ownership | `CaptureSessionOwnershipTests`, `LiveTranscriptSessionIsolationTests`, `CoreJourneyRecordingSourceTests` | Capture exclusion and actual TranscriptionManager callback routing reject superseded runs and stale stop timeouts. |
| History durability | `HistoryPersistenceFailureTests` | Real temporary files: startup read failures, queued append recovery, quarantining corruption and durable recovery after WAL write failure. |

The original filter selected `AutomationIntentSupportTests` instead of the
socket/deadline tests and omitted `ClipboardFieldIdentityPolicyTests`, despite
the documentation claiming those contracts. Exact suite execution checks now
make this type of silent coverage loss a gate failure.

These are component and integration contracts. They do not prove the complete
Speak capture-to-editor journey. A signed app smoke on real macOS remains
necessary for hardware Fn, Input Monitoring, Accessibility, microphone capture,
and Terminal Secure Keyboard Entry.

## Launched-app layer and remaining P0 work (#802)

`CoreJourneyFixtureApp` provides one named editable field and a readiness marker.
`CoreJourneyFixtureUITests` launches only the fixture, types directly into it
using XCTest, and reads the value back. The same bounded `Core Journey Fixture UI`
job now also selects `LaunchUITests` in Debug configuration. That test launches
the actual Speak app and waits for the existing `toolbarRecordToggleButton` in
MainView, which is created only after the production AppEnvironment is built.
It captures the frontmost Speak process identity, switches focus to the fixture,
types there, then activates that same process and checks its PID and the control
again. It never clicks Record or sends a
recording hotkey. The separate hotkey probe below exercises native keyboard delivery. The job uploads its `xcresult`, xcodebuild log, and screenshots
of both apps. This proves bootstrap and focus survival, not transcript delivery.

The explicit `SPEAK_CORE_JOURNEY_PROFILE=<UUID>` launch profile exists only in
Debug builds. It supplies typed, separate UserDefaults and temporary History,
recording, personal lexicon, and auto-correction stores; pronunciation and
dictation profiles use that separate defaults suite. Capture/connection
prewarming, hands-free mode, network listeners, analytics, Fn/input-event-tap monitoring,
credential preloading/sync, voice-edit startup, automatic updates, and launch
cleanup actions are disabled. The test exercises the real manager/view graph
with these startup integrations excluded. Local model singletons may still
discover caches or prepare their storage directories; this does not isolate
every app singleton or test model runtime execution.
The batch variant described below uses genuine system permission status; the bootstrap/probe variants keep their existing disabled-capture permission fixture. Release builds ignore the profile. `CoreJourneyLaunchProfileTests` checks the
typed opt-outs and per-launch settings/storage boundaries; native CI execution
is required to validate the launched-app test itself.

Launched-app tests also pass `SPEAK_CORE_JOURNEY_DIRECTORY` explicitly because
XCTest and its child app can have different process-specific temporary roots.
The shared directory must be the matching `com.justspeaktoit.tests.core-journey.<UUID>`
directly under canonical `/tmp`; the Debug resolver rejects other paths. Profile
state, hotkey evidence and HTTP diagnostics use that same directory, and teardown
attaches the evidence before removing it.

### Native global-hotkey prerequisite

`CoreJourneyHotKeyUITests` opts into `SPEAK_CORE_JOURNEY_HOTKEY_PROBE=1`
alongside the UUID profile. It configures the supported **Control–Option–Shift–K**
chord and starts the production `HotKeyManager` and Carbon backend without a
permission request. XCTest's `typeKey(_:modifierFlags:)` sends keyboard input
while the fixture is frontmost. The test requires two ordered
`keyDown → keyUp → singleTap` sequences, each with the fixture still frontmost,
and the gesture source must be `carbon`. It also checks the same live Speak PID,
background state, unchanged target text, and retained target focus.

An atomic `hotkey-probe.json` snapshot in the isolated profile directory records
registration status, process identity, ordered events, and the actual
`AXIsProcessTrusted()` result. The UI test attaches this snapshot and both app
screenshots to `xcresult` before cleanup. Registration/input failures fail the
test; no permission-denied skip or internal event injection exists. The existing
`Core Journey Fixture UI` job selects this suite with the bootstrap/fixture suites
under its ten-minute timeout. This is new native coverage pending cold-runner CI
validation, not an established flake-rate or full-journey claim.

This probe intentionally leaves MainManager's recording listeners disabled; its
listeners only observe the real engine. It proves the global keyboard boundary,
not MainManager orchestration, capture, transcription, clipboard, insertion, or
History. It does not prove Fn, a held physical key, Input Monitoring, or an
Accessibility grant. Microphone and Accessibility remain denied in the profile.
The AX diagnostic is evidence about the launched process, not an override.

### Integrated batch clipboard journey

`CoreJourneyBatchUITests` opts into `SPEAK_CORE_JOURNEY_BATCH=1` alongside the UUID
profile. A real global Control–Option–Shift–K double-tap starts MainManager's
production session. A separate tap stops it after the configured gesture window.
The test never calls recording, transcription, or output methods directly.

The optional `RecordingCaptureSource` boundary inside `AudioFileManager` supplies
a fixed 250 ms, 16 kHz mono PCM WAV instead of opening a microphone. The normal
nil source keeps AVAudioRecorder and its physical device/permission checks. The
fixture is a synthetic waveform, not recognised speech. Its actor supports start,
stop, cancellation and owner isolation; focused tests decode the actual WAV and
check cancellation, duplicate admission, and immediate reuse.

WireUp supplies a real `OpenRouterAPIClient` with an ephemeral URLSession and a
fixture-only key provider. The URLProtocol intercepts every request on that
session and rejects unexpected hosts, methods, keys, models, streaming requests,
or audio bytes. It returns the known transcript only when the actual serialized
`input_audio` is byte-for-byte the recording fixture. The real batch routing,
request construction, response decoding, post-processing-off decision, output,
and History persistence all run. No real credential, paid API, microphone,
permission override, or external provider request is used.

The batch profile reads **genuine system permissions** and explicitly selects the
user's Clipboard output setting, with clipboard restoration disabled. On macOS
this setting writes the clipboard and attempts PID-directed Command-V. The test
always requires the exact final clipboard text and one durable History item
with raw text, no processed text, batch-only usage, clipboard output, captured
destination, recording duration/file, and successful production stage events.
While recording, both the fixture and clipboard must retain their original text.

If the launched process genuinely has `CGPreflightPostEventAccess()`, the test
also requires exactly one insertion in the original focused fixture. Otherwise
it requires the field to remain unchanged and explicitly attaches the native
insertion limitation. AX and event-posting status, Carbon events, production
states, accepted/rejected HTTP request counts, History JSON, and screenshots are
attached to `xcresult`. This is a full batch **clipboard-route** journey; it does
not claim a physical microphone, permission-denial regression, direct AX
insertion, or native editor delivery on a runner without posting permission.

The native CI job selects all four UI suites under its ten-minute timeout.
`scripts/verify-core-journey-ui.py` reuses the required gate's XCTest parser and
fails missing, all-skipped, partially-skipped, or zero-test suites, even after a
successful xcodebuild exit. Its `coverage.json` is uploaded with the native logs.
Native compilation and repeated cold-runner execution remain necessary before
claiming the expanded journey is validated or the flake/time targets are met.

The native P0 matrix is not complete. Before promoting the launched-app layer
as capture-to-delivery protection, #802 needs the following concrete evidence:

| Scenario | Required assertion |
| --- | --- |
| Cold runner bootstrap | Launch the signed Speak app with isolated settings/history/keychain; establish AX/Input Monitoring permission readiness without skipping or reusing warm-host state. |
| Batch direct insertion | The clipboard-route journey above covers orchestration; direct AX insertion still requires genuine permission bootstrap and exact captured-field delivery on cold runners. |
| Streaming recording | Deliver changing partials and a final; assert replacement in the captured field, no duplicate final, and the final History text. |
| Processing off/on | Run both routes through MainManager and assert the expected raw/processed editor text and History metadata. |
| Provider failure and recovery | Fail a recording, verify actionable UI plus recoverable History, then successfully dictate again in the same process. |
| Target change and empty input | Switch focus during recording and verify the intended delivery/fallback policy; silence must preserve editor and clipboard contents. |
| Physical host release smoke | Exercise Fn with Secure Keyboard Entry, microphone/device interruption, and permission denial using the actual signed release artifact. |

Provider/audio fixtures must enter at production dependency boundaries and the
tests must drive production session orchestration. A test that manually chains
provider, processor, and output calls cannot establish that wiring. Keep native
coverage advisory until permission bootstrap passes on repeated cold hosted
runners, then integrate it into the same required gate and budget.

## Updating the gate

Use explicit suite names and add their coverage to the table. Keep
combinatorial cases in their owning suite. Never add live credentials, network,
blind retries, or unconditional skips. A failure must name its owning XCTest.

The runner's own failure semantics can be checked without Swift:

```sh
python3 -m unittest discover -s scripts/tests -p test_core_journey_gate.py -v
```

These tests cover Apple/portable XCTest log formats, missing and skipped suites,
false-success exits, command errors, retained failure artifacts, and terminating
child processes on timeout. They validate the gate, not the macOS application.
