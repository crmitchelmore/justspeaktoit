# Core dictation journey regression gate

Run the required hermetic gate with:

```sh
scripts/run-core-journey-e2e.sh
```

It has an eight-minute test-command budget and CI has a ten-minute wall-clock
timeout. The gate uses fixed in-memory HTTP/stream events and isolated defaults
and pasteboards; it requires no microphone, provider network, API key, or paid
service. Logs and timing are written to `.artifacts/core-journey-e2e/` and are
uploaded by CI even when the command fails.

## Covered contracts

- Hardware hotkey down/up balance, reset, bounce, and cancellation.
- Batch provider success/error payload handling, including missing and rejected
  credentials.
- Streaming partial/final reconciliation, timeouts, and late events.
- Post-processing off/on, empty input, local processing, and cloud stub use.
- Streaming delivery exactly once without stale or duplicate partial text.
- Empty output preserving the clipboard and unavailable direct insertion
  falling back to it.
- Captured-target delivery, including a changed focused field being delivered
  with a warning rather than becoming a session error.
- Successful recovery after deadline and failure paths through the automation
  boundary.

These are process-boundary contract tests, not a claim that GitHub's unsigned
runner can grant Accessibility or synthesize the physical Fn key. A signed app
smoke on real macOS remains the release check for Terminal Secure Keyboard Entry.
The fixture-app/UI layer described in #802 can be promoted once its permission
bootstrap is reliable on cold hosted runners; it must reuse this same command
and budget rather than creating a second required gate.

## Launched-app layer (in progress)

`CoreJourneyFixtureApp` is the stable Accessibility destination for the next
layer. It exposes one named editable field and readiness marker, avoiding AX
tree drift from depending on TextEdit or third-party editors in CI. Its first UI
test proves the fixture launches with keyboard focus, accepts typed text and can
be read back. The bounded `Core Journey Fixture UI` CI job runs this launched-app
test whenever core-journey paths change so the fixture cannot silently decay.

The next increment launches Speak with an isolated E2E profile and deterministic
provider fixtures, injects the supported hotkey gesture, and asserts delivery
into this field. It remains advisory until Accessibility permission bootstrap
passes the cold-runner flake gate; the existing contract gate stays required.

## Updating the gate

Keep only one representative journey per external branch here. Put
combinatorial cases in the owning suite. Never add live credentials, network,
blind retries, or sleeps. A failure must name the owning XCTest and the CI log
must always be uploaded.
