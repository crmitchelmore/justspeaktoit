# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the performance reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved immediately because no runtime code path or UX latency is changing.

## 2026-03-25 — Issue #157 (HUD capture health)
HUDManager is push-based (no polling); TranscriptionManager has session duration but no latency-bucket signal published to HUD. Latency signal design and update-rate cap are the two open performance items. Not yet approved.

## 2026-03-25 — Issue #149 re-opened design debate
Maintainer asked for concrete cost analysis on repo-memory persistence portability.
Decision: GitHub API signed commits (+1-3s/write) is the cheapest portable fallback that avoids org-level branch exemptions.
Key guardrail: cap memory file sizes (recent-decisions.md to ~10 entries) to keep read/write time constant regardless of mechanism.
External stores (Gist, artifact) are disproportionate for small text files.

## 2026-03-25 — Issue #157 performance-approved confirmed
Labels confirmed: planning:performance-approved already set. Only planning:needs-quality remains.
Guardrails for implementation: rate-limit health updates to state-transitions or ~1 Hz; KVO-driven device enumeration; latency shown as bucket not live average.

## 2026-03-25 — Issue #149: Contents API correction

Live throwaway-branch test showed `PUT /repos/{owner}/{repo}/contents/{path}` produced `verified: false`, `reason: unsigned` here. Do not treat Contents API writes as a signed-commit-safe default. For strict repos, prefer workflow commit signing as the portable default, with branch exemption as a repo-local fallback when governance allows it.

## 2026-03-25 — Issue #149 re-approved after explicit maintainer re-review request
Memory was already correct (Contents API = verified: false). Both remaining options (branch exemption, workflow commit signing) are cost-acceptable from Performance lens. Approved on maintainer's explicit ask. Note: Architecture's reply 4122824374 still cites Contents API as signed-safe — flagged for Architecture to correct.

## 2026-03-25 — Issue #162 (plan-linked PR review)
No runtime code changes. Approved. Guardrails: cap PR review history to ~10 rolling entries in recent-decisions.md; handle large diffs gracefully.

## 2026-03-25 — Issue #174 (port career-framework agentic workflow pattern)
Pure CI/workflow change: GitHub Actions, persona.md files, routing fixes, docs. No runtime code changes. Approved immediately — entirely outside app performance scope.

## 2026-03-25 — PR #175 (port final agentic workflow pattern)
Pure CI/workflow change linked to approved issue #174. No runtime code. Approved immediately — same pattern as PR #161/issue #174. All agentic workflow PRs are outside app performance scope.

## 2026-03-25 — PR #177 approved
docs(agentic-workflows): pure documentation-only PR. Plan issue #176 fully approved. No performance concern. Auto-approved immediately.

## 2026-03-25 — Issue #180 (ignore closed-PR comments in plan-review workflows)
Pure CI guard change. Adds open-PR state check to prevent spurious workflow runs on closed PRs. No runtime code. Approved immediately — reduces workflow fan-out waste, consistent with prior agentic-workflow pattern approvals (#174, #176).

## 2026-03-25 — PR #181 (ignore closed PR comments — implementation)
Pure CI guard change linked to approved issue #180. Approved immediately — same pattern as PR #175/#177. All agentic-workflow CI-only PRs are outside app performance scope.

## 2026-03-26 — PR #186 (AgenTek planning team improvements)
Pure CI/agentic-workflow change (new planning roles, persona enrichment, inter-agent memory). No runtime code. Blocked only on missing linked planning issue — PR body has no Closes/Fixes/Refs link to a planning:ready-for-dev issue. Same class as approved PRs #175/#177/#181 but those had explicit issue links.

## 2026-03-26 — PR #188 (add Riley Tan Design/UX role)
Pure CI/agentic-workflow change. No runtime code. Blocked on missing linked planning issue — same as PR #186. Fan-out increases 7→8 workflow runs/event; acceptable. Will approve immediately once a planning:ready-for-dev issue link is provided.

## 2026-03-26 — PR #191 (disable failure issue creation on all workflows)
Pure CI/workflow change. No runtime code. Blocked on missing linked planning issue — same class as PR #186/#188. Will approve immediately once planning:ready-for-dev issue link is provided. No app performance concern.
