# Modulate opening-audio qualification

Issue [#947](https://github.com/crmitchelmore/justspeaktoit/issues/947) defers
production buffering changes until a real startup-loss reproduction. This
harness tests the current shared `ModulateLiveClient` / `StreamingProviderSession`
through the actual Apple `URLSessionStreamingConnection`, with synthetic PCM
and a loopback-only peer. It redirects the provider origin through the existing
connection factory; it never contacts Modulate or reads a microphone/key.

The four cases cover normal client-start-before-capture ordering, separate
prestart preroll, a failed held upgrade, and stop/restart with the old upgrade
released late. HTTP101 stays held until an explicit control request. Readiness
and terminal-stage waits use signalled bounded barriers; teardown releases
owned barriers and cancels sessions. Task-state inspection is bounded too.

The normal case offers ten 100ms PCM chunks before HTTP101, followed by two
live chunks. This represents one second of opening PCM; it does not assert one
second of elapsed network latency. Receipts record the actual hold duration,
ordered synthetic IDs, byte totals, exactly one WAV header and verified end.
Before release the actual Apple task must be running while its open callback,
native sends and received PCM remain zero. This distinguishes task state from
handshake readiness without changing production transport or buffer policy.

Use Xcode Apple Swift and a clean, exclusively owned checkout. Retain exclusive
checkout ownership through preparation, qualification and cleanup: no other editor,
agent or watcher may write there. Coordinate the shared build lease separately;
that lease does not enforce checkout ownership. Choose external temporary storage
on a space-constrained Mac.
These commands prepare testing-enabled release products and use the exact same
isolated scratch path for build and qualification:

```sh
modulate_scratch="$(mktemp -d "${TMPDIR%/}/modulate-opening.XXXXXX")"
# Preparation uses the runner's tested deletion-only, exclusive lockfile restore.
SPEAK_PORTABLE_CORE=1 python3 -B - "$modulate_scratch/build" <<'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys

spec = importlib.util.spec_from_file_location("modulate_gate", "scripts/qualify-modulate-opening-audio.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
lock = gate.admit_portable_lock(Path.cwd())
try:
    subprocess.run(["xcrun", "swift", "test", "list", "--configuration", "release", "--jobs", "2",
                    "--scratch-path", sys.argv[1]], check=True)
finally:
    gate.restore_deleted_portable_lock(lock)
PY
SPEAK_PORTABLE_CORE=1 python3 -B scripts/qualify-modulate-opening-audio.py \
  --output-dir "$modulate_scratch/receipt" -- \
  xcrun swift test --configuration release --jobs 2 --skip-build \
  --scratch-path "$modulate_scratch/build" \
  --filter ModulateOpeningAudioQualificationTests
```

The output directory must be new. Both preparation and qualification refuse an
existing edited, nonregular or unverifiable portable lockfile before starting
their command. If exclusive ownership is lost, stop and reconcile in a separate
owned checkout; do not force restoration over another writer's data.
The runner owns and bounds its child process
groups, joins its peer reader, preserves command failures/timeouts, and writes
`tests.log`, `peer.log` and `qualification.json`. It reuses the canonical XCTest
completion parser and requires all four exact `SpeakPortableTests` cases once
with zero skips or failures; a missing/wrong filter, all-skipped FoundationNetworking run or bare
exit zero fails qualification. On interruption it cleans up its owned groups.
For the portable graph it restores only an initially HEAD-identical regular
`Package.resolved` when it is absent after the owned command. Under exclusive
checkout ownership, that deletion is attributable to the command. The snapshot
and deletion diff cannot establish attribution if an arbitrary writer violates
that contract. Restoration never overwrites an existing path, and exclusive
creation preserves a competing creator's path; this is not synchronization of
arbitrary concurrent writers. CI runs it after the existing portable Apple build and
retains the receipt artifact.

## Source-state evidence

The receipt adds timed source observations before harness admission, after owned
process cleanup before lock restoration, and after restoration. Each records HEAD,
Git-visible path/status (including rename origins and untracked paths), selected
tracked-input blobs/worktree hashes and explicit `Package.resolved` state. File
contents, untracked-file hashes and environment values are not included. Output
directory membership is reported separately; it never proves a change harmless.
Hash/status limits and collection failures are explicit evidence gaps.

The Mac portable workflow also captures immediately before and after its existing
full build/test command, including that step's outcome, in the separate advisory
`portable-macos-source-state` artifact. The original Modulate artifact layout stays unchanged.
These new observations are advisory: they neither relax existing test failures nor
add a required gate. Missing/partial captures are not clean-source acceptance.
They require exclusive checkout ownership and do not attest the compiler's actual
reads, caches or external dependencies. Harness-only `--skip-build` observations
cannot establish the earlier compiled tree. Earlier receipts containing only a
post-test dirty Boolean cannot recover exact dirty paths retroactively.

A passing synthetic result establishes only these bounded scenarios on the
current shared client. It does not establish physical iPhone/TestFlight opening
speech, arbitrary handshake duration/overflow, real-provider connectivity, or
the separate macOS Modulate controller. Observed loss must be reported before
any production correction; no buffer change is part of this harness.
