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

Use Xcode Apple Swift and a clean checkout. Coordinate the shared build lease
where applicable; choose external temporary storage on a space-constrained Mac.
These commands prepare testing-enabled release products and use the exact same
isolated scratch path for build and qualification:

```sh
modulate_scratch="$(mktemp -d "${TMPDIR%/}/modulate-opening.XXXXXX")"
SPEAK_PORTABLE_CORE=1 xcrun swift test list --configuration release --jobs 2 \
  --scratch-path "$modulate_scratch/build"
# The dependency-free preparation removes this tracked Apple lockfile.
# Restore only that generated deletion in this initially clean checkout.
git restore --source=HEAD -- Package.resolved
SPEAK_PORTABLE_CORE=1 python3 -B scripts/qualify-modulate-opening-audio.py \
  --output-dir "$modulate_scratch/receipt" -- \
  xcrun swift test --configuration release --jobs 2 --skip-build \
  --scratch-path "$modulate_scratch/build" \
  --filter ModulateOpeningAudioQualificationTests
```

The output directory must be new. The runner owns and bounds its child process
groups, joins its peer reader, preserves command failures/timeouts, and writes
`tests.log`, `peer.log` and `qualification.json`. It reuses the canonical XCTest
completion parser and requires all four exact `SpeakPortableTests` cases once
with zero skips or failures; a missing/wrong filter, all-skipped FoundationNetworking run or bare
exit zero fails qualification. On interruption it cleans up its owned groups.
For the portable graph it restores only an initially HEAD-identical regular
`Package.resolved` deleted by its command, using exclusive creation to preserve
other writers' edits. CI runs it after the existing portable Apple build and
retains the receipt artifact.

A passing synthetic result establishes only these bounded scenarios on the
current shared client. It does not establish physical iPhone/TestFlight opening
speech, arbitrary handshake duration/overflow, real-provider connectivity, or
the separate macOS Modulate controller. Observed loss must be reported before
any production correction; no buffer change is part of this harness.
