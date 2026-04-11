# Recent Decisions

## 2026-03-25 — Issue #174: Approved (second pass)
Maintainer clarification resolved three blockers: two-phase smoke-test, atomic removal of named files, persona.md sourced from career-framework. Idempotent reconcile confirmed.

## 2026-03-25 — PR #175: Approved (first pass)
Workflow/docs-only PR. Pattern: workflow-only PRs that deliver exactly the approved plan scope need no quality blockers.

## 2026-03-26 — PRs #186, #189, #191: Blocked (missing plan link)
Pattern: always require explicit plan link (Plan issue: #N or Closes #N) even for small workflow-only PRs.

## 2026-04-07 — Issue #246: First pass (Deepgram incremental append)
Perf optimisations that change accumulation logic need a correctness assertion alongside the benchmark.

## 2026-04-08 — Issue #270: First pass (iOS text-loss on pause)
Three failure modes: commitIfImplicitReset thresholds, error path discards latestResult, silent task termination. No SpeakiOSTests in Package.swift — iOS commit logic cannot be unit-tested via make test.

## 2026-04-08 — Issue #246: Approved (second pass)
Scope resolved: Files section = Deepgram only. XCTAssertEqual for final transcript text required at PR stage.

## 2026-04-08 — PR #128: Blocked (docs-only, missing plan link)
Plan link required even for docs-only PRs.

## 2026-04-08 — Issue #271: Approved (landing-page CSS fix)
No automated tests exist for landing page. Manual browser verification is appropriate bar.

## 2026-04-08 — Issue #283: Approved (one-line import fix)
Compiler-enforced fixes with zero logic change approve immediately.

## 2026-04-08 — Issue #256: Approved (test-addition only)
Pure value-type assertions, verifiable run commands approved on first pass once source confirmed.

## 2026-04-09 — Issue #271: Re-approved (label state contradicted memory)
Pattern: when label state contradicts memory, re-verify issue scope before re-applying approval.

## 2026-04-09 — Issue #270: Re-approved (second /doit reset labels)
Second /doit reset labels but plan unchanged from 2026-04-08 full team approval. Pattern: when second /doit resets labels, verify plan is unchanged and re-approve immediately.

## 2026-04-11 — Issue #299: No action (issue_comment on closed bot issue)
Workflow triggered by owner comment closing bot-generated perf planning issue #299. No PR attached. Rule: issue_comment trigger requires PR — no action taken. Pattern: agentic-workflow cleanup comments on bot issues fire the workflow but must be ignored.
