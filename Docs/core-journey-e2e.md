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
successful test-command exit, elapsed time, and gate errors.

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
| Recording ownership | `CaptureSessionOwnershipTests`, `LiveTranscriptSessionIsolationTests` | Capture exclusion and actual TranscriptionManager callback routing reject superseded runs and stale stop timeouts. |
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
`CoreJourneyFixtureUITests` launches **only the fixture**, types directly into
it using XCTest, and reads the value back. The bounded `Core Journey Fixture UI`
job uploads its `xcresult`, xcodebuild log, and final screenshot. This checks
that the destination fixture works; it does not launch Speak or prove Speak
inserts a transcript.

The native P0 matrix is not complete. Before promoting the launched-app layer
as capture-to-delivery protection, #802 needs the following concrete evidence:

| Scenario | Required assertion |
| --- | --- |
| Cold runner bootstrap | Launch the signed Speak app with isolated settings/history/keychain; establish AX/Input Monitoring permission readiness without skipping or reusing warm-host state. |
| Batch recording | Trigger the supported recording gesture; inject a deterministic audio/provider boundary; stop; read exactly one final transcript in the fixture and the matching persisted History item. |
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
