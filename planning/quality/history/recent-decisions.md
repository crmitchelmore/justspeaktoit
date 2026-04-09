# Recent Decisions

## 2026-03-25 — Issue #162: Plan-linked PR review
Concrete deterministic decisions (not just intent) required before approval.

## 2026-03-25 — PR #161/#175/#181: Workflow-only PRs
Workflow/docs-only PRs that match scope exactly approve on first pass. Plan link required even for docs PRs.

## 2026-04-07 — Issue #246: Deepgram incremental append
Perf optimisations changing accumulation logic need a correctness assertion alongside the benchmark (XCTAssertEqual for final transcript text).

## 2026-04-08 — Issue #270: iOS text-loss on pause
No SpeakiOSTests in Package.swift — iOS commit logic cannot be unit-tested via make test. Key constraint to check before proposing iOS test coverage.

## 2026-04-08 — PRs #186/#189/#191: Plan link required
Always require explicit plan link (Plan issue: #N or Closes #N) even for small/hotfix PRs.

## 2026-04-08 — PR #128: Docs-only, missing plan link
Pattern continues: plan link required even for docs-only PRs.

## 2026-04-08 — Issue #271: Landing-page CSS fix
No automated tests exist or expected. Manual browser verification is the appropriate test bar for landing-page fixes.

## 2026-04-08 — Issue #283: Missing import fix
Compiler-enforced fixes with zero logic change approve immediately. Build failure is the complete verification story.

## 2026-04-08 — Issue #256: Test-addition issue
Test-addition issues with pure value-type assertions and verifiable run commands approve on first pass once source is confirmed.

## 2026-04-09 — Issue #157: Re-approved (second /doit cycle)
Plan core (CaptureHealthSnapshot, three triggers, static LatencyTier) unchanged. Re-approved. New tension: Product wants health shown in idle/ready state; Design said recording/failure only. Named as non-blocking to quality but required resolution at PR stage. Pattern: when /doit re-opens a plan, check for new cross-role conflicts before re-approving.
