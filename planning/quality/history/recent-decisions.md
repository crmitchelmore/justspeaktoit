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

## 2026-03-25 — PR #161
First PR through new plan-review lane (bootstrapping). Blocked on: (1) PR body missing `Plan issue: #162`, (2) issue #162 not yet `planning:ready-for-dev`. These are structural blockers per the review protocol, not style nits.

## 2026-03-25 — PR #161 approved

PR #161 adds the PR plan-review lane (five-role, plan-linked). Approved because:
- Issue #162 was fully planning-approved before PR opened.
- Reconcile script guards the all-open-PRs fallback with a `plan-review:` label check.
- Bot-follow-up comment body handling is safe (prefix comparison only, no shell interpolation).
- PR template update clearly prompts for a real `Plan issue:` number.
- No Swift code changes; no test suite impact.
