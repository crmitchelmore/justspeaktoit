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
| Provider frames and error text appear in public logs | Private free-form content with public event/type/code metadata | #903 |
| Missing or skipped contract suites produce a green journey check | Required execution evidence for 14 suites, real socket recovery coverage, controlled failure artifacts and process-group timeout cleanup | #904 |
| Watch transport completion deletes audio before durable transcription | Persist application acknowledgement before deletion, atomic phone journal completion, recovery receipts and finite reconciliation passes; disk-failure/relaunch/ordering tests | #906 |
| Repeating timers retain history and playback owners | Weak selector proxy and lifecycle/deallocation regressions | #907 |
| Cleanup decodes every audio file and can include active work | Metadata-only serialized snapshots, startup/active ownership checks, damaged-audio and snapshot regressions | #908 |
| Release and journey failures do not block the protected check | Existing protected context aggregates all CI workers using workflow-owned result predicates; failure/skip/missing-state fixtures | #909 |
| Automatic releases race validation or installation smoke passes an unchanged app | Exact validated main SHA, serialized tags, tag-pinned iOS dispatch, prepublication signed-DMG replacement witness and owned-process launch checks | #909 |
| Stale callbacks, duplicate stops, or cancelled startup lose capture ownership | Captured-run teardown, terminal ownership guards, startup cancellation and cleanup; eleven manager/switcher regressions | #910 |

The individual PRs retain review discussions. Their integration branch exercises
the combined changes together before merging. Tests written for Apple platforms
must pass on Apple Swift/Xcode CI; this Linux workspace cannot execute them.
The combined branch passes 65 Node and 25 Python gate/installer regression tests,
plus staged and working-tree whitespace checks. Native CI results remain a
separate merge requirement.

## What the tests prove

The hermetic journey gate exercises production contracts with deterministic
provider boundaries, real local sockets and isolated state. It rejects missing
suite execution, skipped cases, command failures and timeouts. The protected CI
aggregate also requires Release tests, fixture UI, iOS builds, keyboard builds,
and the expected API-compatibility result. The iOS job builds the watch app and
its feature-flagged containing app.

The launched fixture UI still proves only the destination field. It does not
launch Speak and drive a complete hotkey-to-microphone-to-editor journey. The
native P0 matrix and cold-runner qualification remain open in #802. See
[the journey runbook](core-journey-e2e.md) for the exact covered boundaries.

Release installation smoke checks signed bytes, actual bundle/executable
replacement, version/signature, and the exact launched candidate. It does not
establish physical Fn input, every third-party Accessibility tree, Intel runtime
behavior from an arm64 runner, or TestFlight/device background behavior.

## Remaining work and limits

- #911: establish owned WhisperKit download paths before claiming that deleting
  a model reclaims disk space. No shared dependency or system cache was deleted.
- #912: bound local subprocess lifetime and propagate cancellation to its owned
  process tree. Output-memory bounds do not provide execution deadlines.
- #786: iOS startup cancellation still needs coordinated backend task ownership,
  cancellation-aware permission waits and Apple analyzer cleanup. Calling the
  current cancel methods eagerly is insufficient while `isRunning` is false.
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
