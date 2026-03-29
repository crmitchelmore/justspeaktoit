# Recent Decisions

<!-- changelog: 2026-03-29 — noted 2 pattern graduations; trimmed PR-block repetition; no stale entries (all <60 days) -->

## Graduated to principles (2026-03-29)
- **Require plan-issue link on PRs**: 5 decisions (PRs #161, #186, #188, #189, #191) → now in `principles.md`
- **Fast-approve well-scoped tooling issues**: 4 decisions (issues #149, #174, #176, #180) → now in `principles.md`

---

## 2026-03-25 — Issue #157
Approved live capture health HUD feature. Clear user value (diagnose transcription failures without opening settings). All four data sources exist in codebase. Two design decisions deferred to implementation: (1) when health info is visible (recording-phase only vs idle state), (2) latency signal granularity vs existing LatencyBadge. HUD is macOS-only.

## 2026-03-25 — Issue #149 (tooling/infra approval)
Approved agentic workflow live retest. Contents API ruled out (unsigned commits). Remaining paths (workflow signing, branch exemption) preserve value. Portability design delegated to Architecture + Security.

## 2026-03-25 — Issue #162
Approved add plan-linked PR review lane. Clear problem (plan-to-PR gap), specific requirements, testable guardrails. All 5 roles approved.

## 2026-03-25 — Issue #174
Approved port of final career-framework agentic workflow pattern. Tooling-only; no end-user impact. All 7 requirements specific, 5 criteria testable. Triggered Product-validates-on-open gate (live proof of requirement 1).

## 2026-03-25 — Issue #176
Approved docs-only change to record default-branch proof pattern. Evidence-backed (PR #175), strictly scoped to one file with 3 testable acceptance criteria.

## 2026-03-25 — Issue #180
Approved trigger guard fix to ignore closed-PR comments. Concrete problem (PR #161 spurious runs), additive fix, zero approval-model changes.

## 2026-03-25 — PR #161 (plan-issue link pattern, first occurrence)
Initially blocked: missing plan link. After plan link added (#162), all roles approved. Shows that the requirement is enforceable and acceptable.

## 2026-03-25 — PR #175 and #177 and #181
All approved immediately on first valid review. PRs had plan links, diffs matched plans, no scope drift. No product blockers.

## 2026-03-26 — PRs #186, #188, #189, #191 (plan-issue link pattern, repeated)
All blocked for missing `Plan issue: #<n>`. Pattern confirmed stable across significant and trivial scopes alike. Now a standing principle.
