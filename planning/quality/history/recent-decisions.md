# Recent Decisions

## 2026-03-25 — Issues #162, #174, #180: Approved
Patterns: (1) Concrete deterministic decisions required before approval — intent is not enough. (2) Workflow-only PRs with verifiable YAML output approve on first pass. (3) Always require explicit plan link (Closes #N) even for small/hotfix PRs.

## 2026-03-26 — PRs #186, #189, #191: Blocked (missing plan link)
Plan link required for all PRs without exception.

## 2026-04-07 — Issue #246: First pass (Deepgram incremental append)
perf optimisations that change accumulation logic need a correctness assertion alongside the benchmark.

## 2026-04-08 — Issue #270: First pass (iOS text-loss on pause)
Three failure modes named. Key structural constraint: no SpeakiOSTests in Package.swift — iOS commit logic cannot be unit-tested via make test.

## 2026-04-08 — Issue #246: Approved (second pass)
XCTAssertEqual for final transcript text must accompany measure{} — non-negotiable guardrail at PR stage.

## 2026-04-08 — PR #128: Blocked (missing plan link)
Docs-only PRs are not exempt from plan link requirement.

## 2026-04-08 — Issue #271: Approved (web CSS/JS fix)
Landing-page bugs: manual browser verification is appropriate test bar. nav__cta hidden on mobile + body scroll lock are required guardrails.

## 2026-04-08 — Issue #283: Approved (missing import fix)
Compiler-enforced fixes with zero logic change approve immediately. Build failure is the complete verification story.

## 2026-04-08 — Issue #256: Approved (test-only addition)
Test-addition issues with pure value-type assertions approve on first pass once source is confirmed.

## 2026-04-09 — Issues #271, #283: Re-approved (label drift pattern)
Kickoff workflow re-adds needs-quality labels. When memory confirms prior approval and issue scope is unchanged, re-apply quality-approved immediately on subsequent runs.
