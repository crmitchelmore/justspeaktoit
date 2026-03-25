# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the architecture reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved because the issue exists to validate the planning-system architecture, not to modify the application architecture.

## 2026-03-25 — Issue #157 (HUD capture health)
All data sources (PermissionsManager, AudioInputDeviceManager, AppSettings, ModelCatalog.LatencyTier) are SpeakApp-only. CaptureHealth struct belongs in HUDManager.Snapshot, not SpeakCore. MainManager is the right aggregation driver. Static LatencyTier is the safe latency signal — avoid runtime sampling.

## 2026-03-25 — Issue #149: portable planning-memory topology

Maintainer raised the bar from "workflow validation" to "portable pattern for orgs with signed-commit rulesets". Architecture position: prefer Contents API writes (GitHub-verified by default) over branch exemptions or dedicated repos for single-repo cases. Dedicated repo is the right upgrade path at ≥3 repos. Decision rule: switch persistence mechanism before topology.

## 2026-03-25 — Issue #149: final approval

All five planning roles approved. Architecture unblocked after Security approved (resolving signed-commit audit concern for Contents API approach). Issue marked ready-for-dev.

## 2026-03-25 — Issue #157: reached ready-for-dev

All five roles approved. Code Quality confirmed implementation boundary: `CaptureHealthSnapshot` as plain struct in SpeakApp, updated via `HUDManager.updateCaptureHealth(_:)` from MainManager bindings. No high-frequency paths, no separate monitor object, categorical mapping before HUD. Aligns with architecture recommendation. Issue marked ready-for-dev.

## 2026-03-25 — Issue #149: re-approved after planning reopen

Issue was reopened with all roles reset to needs-*. Prior approval rationale unchanged (no app code changes, Contents API topology answer still valid). Re-approved immediately on second pass.

## 2026-03-25 — Issue #149: Contents API correction

Live throwaway-branch test showed `PUT /repos/{owner}/{repo}/contents/{path}` produced `verified: false`, `reason: unsigned` here. Do not treat Contents API writes as a signed-commit-safe default. For strict repos, prefer workflow commit signing as the portable default, with branch exemption as a repo-local fallback when governance allows it.

## 2026-03-25 — Issue #149: re-approved after memory correction (third pass)
Contents API write confirmed not signed-commit-safe (verified: false, reason: unsigned). Corrected portable default: workflow commit signing. Branch exemption as repo-local fallback. Docs/agentic-workflows.md updated to match. Architecture-approved on third pass after memory was corrected by maintainer.

## 2026-03-25 — PR #161 (agentic-workflows PR plan-review)
- Blocked: no linked plan issue in PR body. Cannot approve without one per review protocol.
- PR is adding the plan-review infrastructure itself; may be a bootstrapping case — maintainer should clarify or link the planning issue.

## 2026-03-25 — Issue #162: PR review stage approved

Plan extends the existing `gh-aw` `issue-planning-*` agent pattern with `pr-review-*` agents and a reconcile workflow. `Plan issue: #...` is the explicit coupling mechanism. Label namespace must be `pr-review:*` to avoid collision with `planning:*`. Approved first pass — no app architecture changes, fits existing patterns cleanly.

## 2026-03-25 — PR #161 bootstrapping constraint
PR #161 implements the plan-review lane but was opened before its planning issue #162 was created. Architecture blocked merge pending: (1) `Plan issue: #162` added to PR body, (2) issue #162 reaches `planning:ready-for-dev`. This establishes a precedent: even self-referential workflow PRs must link an approved plan issue before merging.

## 2026-03-25 — PR #161: architecture-approved on second pass
First pass blocked (no plan link, #162 not yet approved). Second pass: `Plan issue: #162` added, #162 reached `planning:ready-for-dev`. All plan requirements satisfied, no drift, no app code changes. Approved.
