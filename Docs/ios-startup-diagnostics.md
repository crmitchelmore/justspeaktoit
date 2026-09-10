# iOS startup diagnostics (issue #972)

Local, run-scoped timing lines for the iOS recording start path.

**This enables measurement; it is not a speed improvement.** Nothing here makes
a start faster. It exists so a start on a real device can be compared against
another start on the same device, with each boundary attributed to the step
that actually crossed it.

Nothing is sent anywhere. The lines go to the device's own unified log and to
no analytics or error-reporting vendor. The diagnostics add no network call.

## What is recorded

One summary per start attempt, plus at most one later line if the first live
partial arrives after the summary.

```
startup run=1a2b3c4d origin=toggleIntent entry=upstream backend=appleAnalyzer \
  outcome=started credentials-ms=41 audio-session-ms=88 engine-start-ms=203 session-start-ms=214
startup-partial run=1a2b3c4d origin=toggleIntent backend=appleAnalyzer first-partial-ms=1830
```

### The complete field allowlist

| Field | Meaning |
| --- | --- |
| `run` | 8 hex characters of an identifier created for this start and discarded with it. Correlates the two lines. Not a user, device or install identifier. |
| `origin` | Closed set: `startIntent`, `toggleIntent`, `controlToggleIntent`, `keyboardHandoff`, `foreground`, `handsFree`, `service`, `coordinator`. A label for the invoking *surface*, never an inferred hardware source. |
| `entry` | `upstream` when the timestamp came from a surface above the start path (an intent's `perform()` entry, a keyboard request), `local` when the start path timed its own entry. |
| `backend` | Closed set: `appleAnalyzer`, `appleLegacy`, `openAIRealtime`, `sharedClient`, `batch`, `simulatorStub`, or `unresolved` when the start failed before a backend was settled. |
| `outcome` | Closed set: `started`, `failed`, `cancelled`. |
| `credentials-ms` | Entry → the credentials wait completed. |
| `audio-session-ms` | Entry → the audio session finished configuring for recording. |
| `engine-start-ms` | Entry → `audioEngine.start()` returned. |
| `session-start-ms` | Entry → the backend's `start()` returned. |
| `first-partial-ms` | Entry → the first non-empty, non-final live partial. |

That table is the whole of it. There is no transcript, prompt, audio, API key,
raw error, device name, route name or persistent identifier in these lines, and
no field outside this list is emitted.

### What the numbers do not mean

- `engine-start-ms` is **not** first audio, not usable speech, not provider
  readiness and not delivery. It is the moment the engine call returned.
- `session-start-ms` is **not** first audio or transport readiness either.
- `first-partial-ms` includes however long the user waited before speaking.
- Batch has no live partial at all, so `first-partial-ms` is simply absent for
  it — that absence is not a slow partial.
- A boundary the start never reached is **absent**, never `0`. Absent means
  "not reached, or not measurable".
- These are wall-clock `Date` readings. **No monotonic precision is claimed.**
  An interval that measures negative under a clock adjustment is reported as
  absent, like any other unmeasurable one.
- `backend=simulatorStub` marks the DEBUG-only simulator transcript stub. It
  has no microphone, no audio session and no engine, so it never carries an
  engine-start measurement.

## Capturing the lines on a physical iPhone

The lines are emitted at `info` level in the app's own subsystem
(`com.justspeaktoit.ios`) under the category `startup`.

### Live, with the phone attached to a Mac

```sh
log stream --device \
  --predicate 'subsystem == "com.justspeaktoit.ios" AND category == "startup"' \
  --style compact
```

Add `--info` if the stream comes back empty; `info`-level messages are not
included by default on every configuration.

To watch a whole start path rather than only the summaries, widen the category:

```sh
log stream --device --info \
  --predicate 'subsystem == "com.justspeaktoit.ios" AND category IN {"startup", "audio", "transcription"}' \
  --style compact
```

### After the fact, from a sysdiagnose

Trigger a sysdiagnose on the phone (both volume buttons + side button, briefly),
then AirDrop or share the archive to the Mac and read its log archive:

```sh
log show --archive <sysdiagnose>/system_logs.logarchive --info \
  --predicate 'subsystem == "com.justspeaktoit.ios" AND category == "startup"' \
  --style compact
```

### Comparing repeated starts

Each line is self-contained, so a plain text filter is enough:

```sh
log show --archive <archive> --info --style compact \
  --predicate 'subsystem == "com.justspeaktoit.ios" AND category == "startup"' \
  | grep '^.*startup ' \
  | sed 's/.*startup /startup /'
```

Group by `origin` and `backend` before comparing anything: a cold Action Button
start, a warm one, a foreground start and a keyboard handoff cross different
work, and built-in and Bluetooth input are different measurements too. Report
individual readings or a range with a sample count. Do not average across
surfaces, and never report these as fleet percentiles or as a saving — a
percentile of a handful of local starts on one device is not a fleet figure,
and none of these numbers measures a change in speed.

There is no in-app diagnostics screen and no exporter; the log is the interface.
