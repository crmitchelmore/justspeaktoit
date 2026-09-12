# SRE review — 5 September 2026

Six Astra reviews covered release delivery, macOS capture lifecycle, network and
privacy boundaries, resource use, iOS/watch recovery, and regression-test coverage.
The findings below were checked against code and reviewed again after fixes.
This record distinguishes implemented protections from native verification still
required; it is not a guarantee that production cannot regress.

## Implemented changes

| Failure mode | Protection and evidence | Review PR |
| --- | --- | --- |
| Random ciphertext slash escaping exceeds QR capacity | Unescaped outer JSON; deterministic worst-case base64 fixture, QR rendering, and envelope round trip | #900 |
| Subprocess logs grow without bound or lose failure details | Bounded stream retention, continued pipe draining, actionable stderr; real oversized-output child regression | #901 |
| Send to Mac retains unpaired channels after shutdown or confuses device ownership | Connection identity ownership, listener generations, eight pending peers, absolute authentication deadline; loopback shutdown/reconnect/admission regressions | #902 |
| Local setup or inference never returns, or cancellation leaves descendants running | Per-stage deadlines, dedicated process groups, nonblocking input/output, bounded teardown; eleven owned-helper regressions | #913 / #912 |
| Provider frames and error text appear in public logs | Private free-form content with public event/type/code metadata | #903 |
| Missing or skipped contract suites produce a green journey check | Required execution evidence for 14 suites, real socket recovery coverage, controlled failure artifacts and process-group timeout cleanup | #904 |
| Watch transport completion deletes audio before durable transcription | Persist application acknowledgement before deletion, atomic phone journal completion, recovery receipts and finite reconciliation passes; disk-failure/relaunch/ordering tests | #906 |
| iOS stop cannot interrupt startup permission waits or Apple teardown | Owned startup tasks, cancellation-aware permission continuation, partial resource cleanup and callback identity fences; nine regressions including all four backends | #913 / #786 |
| Model deletion removes only a marker while downloads remain | Per-model owned storage and verified folder provenance, contained deletion, failure recovery and legacy-cache preservation; fourteen regressions | #913 / #911 |
| Repeating timers retain history and playback owners | Weak selector proxy and lifecycle/deallocation regressions | #907 |
| Cleanup decodes every audio file and can include active work | Metadata-only serialized snapshots, startup/active ownership checks, damaged-audio and snapshot regressions | #908 |
| Release and journey failures do not block the protected check | Existing protected context aggregates all CI workers using workflow-owned result predicates; failure/skip/missing-state fixtures | #909 |
| Automatic releases race validation or installation smoke passes an unchanged app | Exact validated main SHA and current successful CI attempt, serialized tags, tag-pinned iOS dispatch, prepublication signed-DMG replacement witness and owned-process launch checks | #909 |
| Fixture-only UI tests miss Speak bootstrap failures | Launch actual Speak with a narrow DEBUG profile, assert the existing Record toolbar control, then verify the same process survives a fixture focus round trip | #913 / #802 |
| Stale callbacks, duplicate stops, or cancelled startup lose capture ownership | Captured-run teardown, terminal ownership guards, startup cancellation and cleanup; eleven manager/switcher regressions | #910 |

The individual PRs retain review discussions. Their integration branch exercises
the combined changes together before merging. Tests written for Apple platforms
must pass on Apple Swift/Xcode CI; this Linux workspace cannot execute them.
The combined branch passes 76 Node and 25 Python gate/installer regression tests,
plus staged and working-tree whitespace checks. Native CI results remain a
separate merge requirement.

Native CI also caught test-fixture errors: automation requests needed an actual
input path, macOS temporary-directory aliases needed filesystem identity checks,
and the UI test needed Speak's explicit bundle identifier to avoid launching the
destination fixture. The transport overflow probe observes WebSocket handshake
failure directly because the channel wrapper leaves Network's waiting state
pending. It fails if the connection reaches readiness or rejection times out.
Review follow-ups protect active recordings through directory aliases and give
the local runtime source build a separate, cancellable one-hour deadline.
Counted model-use leases now retain files through batch inference and streaming
tail work, even after cancellation or a controller timeout. Both Settings rows
repair the shared batch/streaming selections after deletion. iOS cancellation
drains asynchronously with capture identity checks; missing-recording errors
clear startup state. Watch reconciliation reclaims expired unjournalled audio,
serializing retirement and deletion with incoming delivery.

## What the tests prove

The hermetic journey gate exercises production contracts with deterministic
provider boundaries, real local sockets and isolated state. It rejects missing
suite execution, skipped cases, command failures and timeouts. The protected CI
aggregate also requires Release tests, fixture UI, iOS builds, keyboard builds,
and the expected API-compatibility result. The iOS job builds the watch app and
its feature-flagged containing app.

The UI gate now launches Speak, checks its real toolbar after bootstrap, and
verifies that its original process survives focus switching to the destination
fixture and back. A DEBUG-only profile disables recording, prewarming, input
monitoring and external startup actions, and isolates specified settings/stores.
It does not drive a complete hotkey-to-microphone-to-editor journey. The native
P0 matrix and cold-runner qualification remain open in #802. See
[the journey runbook](core-journey-e2e.md) for the exact covered boundaries.

Release installation smoke checks signed bytes, actual bundle/executable
replacement, version/signature, and the exact launched candidate. It does not
establish physical Fn input, every third-party Accessibility tree, Intel runtime
behavior from an arm64 runner, or TestFlight/device background behavior.

## Remaining work and limits

- Legacy dependency-managed WhisperKit caches are preserved. Removing a legacy
  installation explains this in Settings; downloading again uses owned storage.
- Subprocess teardown covers descendants that remain in the owned process group.
  A kernel-stuck spawn cannot be interrupted, and a killed but unreapable leader
  may need a background reaper holding only its owned PID.
- Apple may continue system-managed asset preparation until its native async call
  observes cancellation. Later microphone/resource acquisition is fenced; known
  partial resources and analyzer teardown are owned by the cancelled startup.
- #802 and #664: finish native capture-to-editor scenarios and the signed target
  app matrix. Physical watch/keyboard interruption and background behavior also
  need device checks.
- #648 / #665: paid-access billing/identity decisions remain unresolved. This
  sweep does not ship the blocked billing implementation.
- Synchronous filesystem reads can still stall the recorder actor; cleanup
  deliberately keeps serialized ownership instead of accumulating detached scans.
  A blocked synchronous `AVAudioRecorder.stop()` also cannot be escaped merely by
  placing a structured task-group timeout around it.
- Send to Mac's existing LAN transport is authenticated but unencrypted. Changing
  that wire protocol needs an explicit compatibility migration.
- History still keeps its full snapshot in memory and preserves failed writes
  losslessly; visible pagination is not a bounded-storage architecture.

The pinned Sentry 9.26.1 source was checked: its `beforeSend` hook also processes
transactions, so the absence of a separate `beforeSendTransaction` hook is not a
demonstrated bug in this version. No provider-key exfiltration incident was found.

For failed validation or delivery, use [release recovery](release-recovery.md).
Workflow changes remain a trusted review boundary; ordinary branch status checks
are not an organization-enforced immutable-workflow policy.
