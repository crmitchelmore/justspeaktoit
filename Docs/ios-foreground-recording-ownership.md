# Foreground recording ownership

`TranscriberCoordinator` claims a run before awaiting credentials. Its
`RecordingLifecycleCoordinator` refuses another start until startup has unwound
or the owned stop has drained; `RecordingStartupOperation` — the same guard the
transcribers use — owns the startup task itself. Cancellation retires the pending
run immediately, cancels its exact provider, and waits for settlement when
shutdown is awaited. The factory exposes cancellation settlement for the existing
Apple analyser and shared-client cleanup tasks. Foreground cancellation retains
ownership until those tasks have finished; stopping the engine alone does not
release the owner. An intentional startup cancellation has no result, History
record or provider error alert. The manual startup action is labelled "Cancel
starting recording"; a finishing recording is labelled "Finishing recording" and
accepts no further taps until its drain settles.

`ForegroundRecordingOwnership.shared` is an app-process guard for the existing
AudioRecordingIntent consumers, not an App Group display flag. It stays owned
through startup, active capture, cancelled-start unwind and normal teardown.
The headless service checks it before claiming its lifecycle and again after
credentials, before allocating resources or publishing shared state; that
acquisition-time refusal unwinds only the refused run's own bookkeeping, never
the Live Activity or App Group flag the foreground owner now holds. Foreground
start also checks the headless lifecycle, including starting and stopping.
`isRunning` and `SharedTranscriptionState.isRecording` retain their recording-only
meaning for the foreground owner. A UUID-scoped release cannot free another run.

The Control toggle keeps its requested-value classifier (#941); the ownership
guard runs before it, on the MainActor, for **both** desired values. The Start,
Toggle and Stop intents read ownership alongside the shared flag. Every other
headless entry — the keyboard hand-off, capture links and quick actions — goes
through `TranscriptionRecordingService.startRecording` and inherits the service's
own guard, so no caller needs a guard of its own.

Callbacks carry the startup run identity and session identity. Cancelled startup
callbacks are ignored, while the current stop can receive its final partials,
which the Live Activity shows as finalisation rather than active capture. The
truthful presentation gate and startup diagnostics bind to the same run identity,
so a first input buffer that arrives while `start()` is still suspended is
attributed to its own run. Hands-free start receives a run handle: its
stop/cancel callbacks cannot act on an unrelated foreground capture when its own
start was rejected or has ended.

## Verification

- `make test` runs the shared ownership and lifecycle tests on macOS. iOS-only
  test bodies are excluded from that run.
- `ForegroundRecordingCoordinatorTests` tests the real coordinator with suspended
  credential loading, provider startup and stop drain, including cancellation,
  construction/permission failures, stale callbacks, hands-free handles and one
  final History result.
- `ForegroundRecordingIntentOwnershipTests` invokes both Control values and the
  existing Start/Toggle/Stop intents while foreground startup, cancellation and
  finalisation are suspended. It also inserts a foreground claim after headless
  preflight but before acquisition.
- The iOS lane builds and runs those tests on a simulator. Building test bundles
  does not establish that their runtime assertions passed.

Physical iPhone validation remains separate: cold-launch with slow credentials
and a permission prompt where available, tap Start then Cancel repeatedly, and
check that no late microphone activation or error alert occurs. Repeat with
Apple live capture and one configured remote backend. While startup, cancelled
unwind and finalisation are delayed, request Control Start/Stop and Action Button
Start/Toggle; check that no competing microphone starts and no foreign stop claims
success. Retry after settlement, then record/stop normally and verify one expected
History entry, truthful Live Activity state, and microphone shutdown. Record the
actual device, iOS version, build and provider observations.
