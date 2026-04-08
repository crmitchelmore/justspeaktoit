# Recent Decisions

## 2026-03-25 — Issue #174: First pass
Workflow/CI-only port from career-framework. Three gaps raised: missing smoke-test protocol, unspecified redundant-layer removal (issue-triage vs product-validation), and persona.md source. Confirmed repo fact: both kickoff and triage currently fire on issues:opened. No PR plan-review workflows exist yet.

## 2026-03-25 — Issue #174: Approved (second pass)
Maintainer clarification resolved all three blockers: two-phase smoke-test protocol, atomic removal of three named files, persona.md sourced from career-framework. Idempotent reconcile confirmed. All five roles approved; ready-for-dev applied.

## 2026-03-25 — PR #175: Approved (first pass)
Workflow/docs only PR. Redundant triage layer removed atomically. PR review guard improved to API-based `pull_request != null` check. Named personas added. No Swift code changes — no test coverage needed. Pattern: workflow-only PRs that deliver exactly the approved plan scope need no quality blockers.

## 2026-03-25 — PR #177: Approved (first pass)
Docs-only PR delivering exactly what issue #176 approved. 3-step proof pattern with concrete repository example. Zero implementation surface — no test coverage needed. Pattern: docs-only PRs that precisely match the approved plan scope are approved immediately.

## 2026-03-25 — Issue #180: Approved (first pass)
Workflow guard tightening. State == 'open' check added to issue_comment path. Key guardrail: each .lock.yml has the guard at TWO locations (main job if: and pre_activation job if:). Dispatcher has one. 11 occurrences total. Pattern: workflow-only changes with verifiable YAML output approve on first pass.

## 2026-03-25 — PR #181
Workflow-only guard fix (closed-PR comments). Lock files + source .md files both updated; guard consistent across all 6 changed files. Approved on first pass — plan scope exact match, no implementation surface concerns.

## 2026-03-26 — PR #186: Initial pass
Workflow/docs-only PR (7 agent persona files + 7 workflow .md files). No Swift code changes. Blocked on first pass for missing plan link — no `Plan issue:`, `Closes #`, or similar in PR body. Precedent: PR #161 was similarly blocked then approved once plan confirmed. Pattern: always require explicit plan link even for small workflow-only PRs.

## 2026-03-26 — PR #189: Initial pass
Crash fix (Data.removeFirst → Data(dropFirst)), 4-line change in TranscriptionManager.swift. Fix is technically correct across all 4 PCM drain loops. Blocked on missing plan link. Pattern consistent with PR #188 and #161. For hotfix-type PRs, the missing plan link is still a protocol blocker.

## 2026-03-26 — PR #191: Initial pass
Workflow-only PR (31 lock.yml + 31 .md files) disabling `GH_AW_FAILURE_REPORT_AS_ISSUE` across all agentic workflows. Blocked: no plan issue link. Pattern consistent with PRs #186, #189, #161.

## 2026-04-07 — Issue #246: Perf improvement for incremental transcript append
Automated perf issue. Two focused concerns raised: (1) scope ambiguity on AssemblyAI (files section says Deepgram only, body says "can be handled"), (2) verification story covers performance (measure{}) but not correctness. `buildFinalResult()` map+join at line 948 correctly identified as a one-shot call, not a hot path — left out of scope. Pattern: always check whether a perf fix has a correctness regression test alongside the measurement, especially when branching logic (replace vs append) is involved.

## 2026-04-08 — Issue #270: First pass (iOS text-loss on pause)
iOS-only SFSpeechRecognizer fix. Three concrete failure modes identified: (1) commitIfImplicitReset heuristic thresholds too coarse, (2) error path in handleRecognitionResult discards latestResult without committing, (3) silent task termination without isFinal. Key structural constraint: no SpeakiOSTests target in Package.swift — iOS commit logic cannot be unit-tested via make test. Pattern: when fix touches heuristic detection logic, require either extraction to testable pure function or explicit device-log verification story.

## 2026-04-08 — Issue #270: Approved (second pass)
Two blockers from first pass resolved by Architecture's (Morgan) comment: both failure modes confirmed (threshold miss + error path data loss), and the error-path fix shape is explicit (commit before return, guard by !isShuttingDownRecognitionTask). Structural verification limitation (no SpeakiOSTests) resolved with PR guardrail requiring device evidence. Pattern: when iOS-only code has no unit test target, approve with device verification guardrail instead of blocking on infrastructure that doesn't exist.
