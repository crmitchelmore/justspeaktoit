# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the quality reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved because there is nothing substantive to implement from a code quality perspective.

## 2026-03-25 — Issue #157
Three blockers raised: (1) ownership shape for health state vs. recording state machine, (2) static vs. measured latency signal, (3) explicit update trigger list. CaptureHealthSnapshot belongs in SpeakApp, not SpeakCore. Test surface is SpeakAppTests unit tests.

## 2026-03-25 — Issue #157 — Capture health HUD
- Confirmed: `CaptureHealthSnapshot` as plain struct on `HUDManager` in `SpeakApp` only
- Static `LatencyTier` sufficient for v1; measured latency is a v2 concern
- Event-driven refreshes on exactly three publishers (permissions, device, model) — no polling
- Dedicated `updateCaptureHealth(_:)` method enforces clean call sites
- Key quality rule: plain struct with value semantics = trivially unit-testable without mocking

## 2026-03-25 — Issue #149: Contents API correction

Live throwaway-branch test showed `PUT /repos/{owner}/{repo}/contents/{path}` produced `verified: false`, `reason: unsigned` here. Do not treat Contents API writes as a signed-commit-safe default. For strict repos, prefer workflow commit signing as the portable default, with branch exemption as a repo-local fallback when governance allows it.

## 2026-03-25 — Issue #149: Post-correction round 2
- Contents API confirmed unsigned in this repo. Rollout contract must not use it.
- Architecture comment 4122824374 is stale (still references Contents API). Does not resolve portability question.
- Quality approval blocked until Architecture corrects stance and Security confirms preferred path (workflow signing vs branch exemption).
- Proposed rollout contract: 5 checkpoints — pre-flight, choose path, verify end-to-end, document, correction protocol.

## 2026-03-25 — Issue #149 (corrected): Agentic workflow live retest
Previous memory for issue #149 was stale (referenced a different Contents API topic). Actual issue is a workflow smoke test. No code quality concerns — approved immediately. Pattern: for issues with no implementation surface, approve without conditions.

## 2026-03-25 — PR #161
- Blocked for missing Plan issue linkage. Protocol requires `Plan issue: #<n>` or closing keyword before any approval can be granted.

## 2026-03-25 — Issue #162: Plan-linked PR review stage
All five roles approved after maintainer provided explicit decisions on PR template syntax, label isolation, and memory scope. The pattern of requiring concrete deterministic implementation decisions (not just intent) before approval proved correct here — all gaps were closeable with a single maintainer synthesis comment.

## 2026-03-25 — PR #161: Approved
Implementation matches plan #162: PR template, label isolation, agent-based plan-link validation, and scoped role memory all delivered. Prior block was stale (plan link WAS present). Approved on second pass.

## 2026-03-25 — Issue #174: First pass
Workflow/CI-only port from career-framework. Three gaps raised: missing smoke-test protocol, unspecified redundant-layer removal (issue-triage vs product-validation), and persona.md source. Confirmed repo fact: both kickoff and triage currently fire on issues:opened. No PR plan-review workflows exist yet.

## 2026-03-25 — Issue #174: Approved (second pass)
Maintainer clarification resolved all three blockers: two-phase smoke-test protocol, atomic removal of three named files, persona.md sourced from career-framework. Idempotent reconcile confirmed. All five roles approved; ready-for-dev applied.

## 2026-03-25 — PR #175: Approved (first pass)
Workflow/docs only PR. Redundant triage layer removed atomically. PR review guard improved to API-based `pull_request != null` check. Named personas added. No Swift code changes — no test coverage needed. Pattern: workflow-only PRs that deliver exactly the approved plan scope need no quality blockers.

## 2026-03-25 — PR #177: Approved (first pass)
Docs-only PR delivering exactly what issue #176 approved. 3-step proof pattern with concrete repository example. Zero implementation surface — no test coverage needed. Pattern: docs-only PRs that precisely match the approved plan scope are approved immediately.
