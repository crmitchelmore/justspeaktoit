# iOS test execution evidence

The CI iOS job runs `SpeakiOSTests` and `SpeakiOSUITests` without Xcode's
`-quiet` flag. Its full console log retains XCTest completion records; only
the last 50 lines are echoed into the job log.

`scripts/verify-ios-test-evidence.py` uses the shared XCTest case parser to
require at least one passing case with each selected target's exact module
identity. It additionally requires passing cases from both
`SpeakiOSTests.OpenRouterAudioSettingsTests` and
`SpeakiOSTests.OpenRouterVoiceCancellationTests`. A failed case in either
selected target, or any failed/skipped case in either critical suite, rejects
the gate. A failed, cancelled, or skipped test command cannot pass the gate.

Every run uploads `ios-test-summary-<attempt>` with seven-day retention. Its
JSON includes the command outcome, distinct completed case count, per-target
and per-suite pass/fail/skip counts, and gate errors. It contains no transcript,
raw console output, screenshots, or test method names. Repeated console lines
are deduplicated; a failed or skipped attempt remains visible even if the same
case subsequently passes. Consequently, per-status counts can sum above the
distinct case count when retries have different outcomes.

Full `SpeakiOS.xcresult` and `ios-tests.log` artifacts remain limited to failed
or cancelled jobs, including execution-evidence failures. A missing log still
produces a failing JSON summary. Suite headings, zero-test summaries, and
unqualified test names cannot establish target execution. If an Xcode update
stops emitting recognized module-qualified completion records, the gate fails
closed and retains diagnostics; it does not infer success from source files or
the test command's exit status alone.

The verifier reads at most 64 MiB plus one byte from the full log. A larger log
fails closed and produces a summary without parsing its prefix: a truncated
transcript cannot prove that all required tests ran without failures or skips.

Portable regression checks:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*evidence.py' -v
python3 -m unittest discover -s scripts/tests -p 'test_core_journey_gate.py' -v
```
