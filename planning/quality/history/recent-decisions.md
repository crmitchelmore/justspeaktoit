# Recent Decisions

## 2026-03-25 — Issue #162: Plan-linked PR review stage
All five roles approved after maintainer provided explicit decisions on PR template syntax, label isolation, and memory scope. Pattern: concrete deterministic decisions (not just intent) are required before approval.

## 2026-03-25 — PR #161: Approved
Implementation matches plan #162. Prior block (missing plan link) was stale — plan link WAS present. Approved on second pass.

## 2026-03-25 — Issue #174: Approved (second pass)
Maintainer clarification resolved three blockers: two-phase smoke-test protocol, atomic removal of three named files, persona.md sourced from career-framework. Idempotent reconcile confirmed.

## 2026-03-25 — PR #175: Approved (first pass)
Workflow/docs-only PR. Pattern: workflow-only PRs that deliver exactly the approved plan scope need no quality blockers.

## 2026-03-25 — Issue #180 / PR #181: Approved (first pass)
Workflow guard tightening. State == 'open' check in 11 YAML locations. Pattern: workflow-only changes with verifiable YAML output approve on first pass.

## 2026-03-26 — PRs #186, #189, #191: Blocked (missing plan link)
Consistent pattern: always require explicit plan link (Plan issue: #N or Closes #N) even for small workflow-only PRs. Hotfix PRs are not exempt.

## 2026-04-07 — Issue #246: First pass (Deepgram incremental append)
Two concerns raised: (1) scope ambiguity on AssemblyAI, (2) measure{} proves performance but not correctness. Pattern: perf optimisations that change accumulation logic need a correctness assertion alongside the benchmark.

## 2026-04-08 — Issue #270: First pass (iOS text-loss on pause)
Three failure modes: commitIfImplicitReset thresholds too coarse, error path discards latestResult, silent task termination without isFinal. Key structural constraint: no SpeakiOSTests in Package.swift — iOS commit logic cannot be unit-tested via make test.

## 2026-04-08 — Issue #246: Approved (second pass)
Scope resolved: Files section = Deepgram only. Correctness test deferred to PR stage as non-negotiable guardrail — XCTAssertEqual for final transcript text must accompany measure{}.
