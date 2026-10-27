# iOS History persistence isolation

Issue #1118 increment two retains the existing local store and sync disclosure.
`iOSHistoryManager` owns observable state on MainActor. Its `IOSHistoryPersistence`
actor facade admits typed operations synchronously to one private serial worker
before awaiting a result. That worker owns authoritative rows, recovery state,
JSON encoders/decoders, SHA256 digests and all injected `StorageIO` calls. It never
synchronously calls MainActor. `StorageIO` closures are `@Sendable`; fixtures that
share controls with the worker synchronize them explicitly.

Production recording completion, foreground capture, keyboard finalisation,
Watch/shared import, recovery, App Intents, History UI, polish and sync/lifecycle
paths await operation receipts. The production singleton performs no initial
store read in its constructor. Views and intent readers await readiness. Legacy
public synchronous APIs and immediate-load test construction remain compatible:
they block their caller on the **same** worker and report actual durability.
There is no semaphore bridge to an actor. The persistence bridge creates no Swift task for each row.

An admitted operation is not revoked when its awaiting task is cancelled. Its
receipt describes that operation's durable primary or recovery write, even if a
later operation supersedes the UI snapshot. Cancellation before a provider result
is accepted still prevents that result from being admitted. A cancelled capture
cannot resume external delivery after its History write settles. An automatic
polish operation retains terminal cleanup through its accepted History write;
expiration can still end the OS background allowance.

Local deletion records its own existing-format tombstones before accepting a
recovery-only commit. If both writes fail, pending/recovery mutation intent is
restored along with the visible row. A later retry cannot silently perform a
rolled-back deletion. Notification, Handoff and sync effects use the owned receipt
and same-ID admission, rather than depending on an unrelated UI publication.

The following storage contracts remain unchanged:

- The primary `transcription-history.json` and `.recovery` paths and JSON shapes.
- ISO8601 dates, sorted-key digest input, legacy array sidecar decoding and
  complete-file-protection-until-first-authentication atomic writes.
- Positive missing-file detection; unreadable or corrupt files are preserved.
- Same-second edits, per-row `baseDigests`, pending deletes, changed-primary wins
  after commit/failed cleanup, and retryable recovery cleanup errors.
- The nine scalar `SyncableHistoryEntry` fields. Local errors, rich diagnostics,
  file URLs and network payloads do not become remote fields. No container change.

Remote changes retain the 250 ms debounce. Durable commit precedes remote token
or acknowledgement completion, and only the committed remote revision is cleared.
An ID-only full-sync acknowledgement binds conservatively to its first offered
revision until consumed. Overlapping status queries cannot replace that offer.
An ambiguous old acknowledgement leaves a newer row pending; this can require an
extra reconciliation retry. While owned direct uploads for an ID are in flight,
generic callbacks cannot consume its full-sync offer. Each direct wrapper marks
only its captured, still-current revision after its upload returns.

Background flush retains an owned background assertion through its await. App
termination retains the truthful synchronous compatibility flush because an
asynchronous termination task has no guaranteed execution window.

## Qualification

The retained synchronous recovery/persistence/reconciliation suites and new
signalled delayed-read/write, cancellation, FIFO, tombstone, late-ack, direct/full
sync and Watch durability regressions require native Apple execution. Syntax
parsing and cached SwiftLint do not establish type checking, actor responsiveness,
file protection or runtime success. Native iOS/full history/core/sync, API comparison
against the base, and installed upgrade/restart checks remain required.

Device checks include seeded old history, add/polish/delete across restart, cold
headless recording preserving prior rows, unavailable storage with truthful retry
UI, unchanged sync banner and retained Watch source until durable acknowledgement.
No new storage format, CloudKit schema, WAL migration or storage-root choice is
introduced by this increment.
