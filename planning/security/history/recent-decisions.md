# Recent Decisions

## 2026-03-25 — Foundational patterns (issues #149, #157, #162, PRs #161, #175, #177, #181)
- `planning/*` branches unprotected; GITHUB_TOKEN commits via `github-actions[bot]` acceptable.
- Workflow permissions: `permissions: {}` top-level, least-privilege job overrides. Fork guard required on all PR workflows.
- Merge-readiness must be label-state-driven, not comment-parsed.
- Contents API writes produce `verified: false` on strict repos — prefer workflow commit signing.
- Persona/memory files on `planning/*` branches are low risk (isolated, no code execution).
- HUD fields must use categorical labels, not raw API error bodies.

## 2026-03-25 — Issue #174 (career-framework workflow port)
Blocked on one question: PR plan-review reconcile with `issue_comment` trigger — need confirmation it determines merge-readiness from label state only, not from comment content, and runs with least-privilege. Private repo + triage removal noted as low concern. Persona memory files assessed as low risk (same isolation pattern).

## 2026-03-25 — Issue #174: Approved (both blockers resolved by maintainer)
PR reconcile: label-state-only decision (no comment parsing for merge-readiness). Permissions: `contents: read`, `issues: write`, `pull-requests: write`. `issue_comment` trigger is idempotent nudge only. Atomic removal avoids double-fire window. Named persona files copied from career-framework — same isolation pattern, low risk.

## 2026-03-25 — PR #175 (port final career-framework agentic pattern)
Approved. Implementation matches issue #174 plan exactly: fork guard on all PR workflows, `permissions: {}` top-level with least-privilege job overrides, reconcile is label-state-only, direct Product-validation-on-open replaces triage overlap, named personas (Priya Shah) added to security agent. No new attack surface; workflow-only changes.

## 2026-03-25 — Issue #176 (document default-branch proof pattern)
Documentation-only change to agentic-workflows.md. Approved immediately: no code, no new attack surface, no trust boundaries. The documented proof pattern (validate on main post-merge) is a security-positive practice worth encouraging.

## 2026-03-25 — PR #177 (docs: default-branch proof pattern)
Approved immediately. Documentation-only change to `Docs/agentic-workflows.md` linked to pre-approved issue #176. No code, no attack surface, no trust boundaries. Matches approved plan exactly.

## 2026-03-25 — PR #181 (ignore closed-PR comments guard)
Approved. Single-line guard `github.event.issue.state == 'open'` added to all 5 plan-review role workflows and the bot dispatcher. Security-positive: narrows execution scope, no permissions or trust boundary changes. All five approvals were already in place; this run confirmed the prior stance.

## 2026-03-26 — PRs #186, #188, #191 (workflow changes)
All blocked on missing linked plan issue (governance only). Implementations were clean: correct permissions, fork guards, stale-close scoped to labelled issues only. PRs #186 and #188 closed without merge.

## 2026-04-07 — MCP auth gap pattern (issues #223, #214, #201; PRs #247, #215, #184, #166, #246, #265)
All GitHub MCP reads returned empty arrays on this private repo. Took no action in each case. Pattern: when MCP returns empty, do not approve; wait for re-trigger. Some items were issues not PRs (no PR number in context).

## 2026-04-08 — Issue #270: Approved (iOS transcription text persistence fix)
Self-contained local state management fix in `iOSLiveTranscriber.swift`. No new permissions, no network flows, no credentials. Trust boundary unchanged. Existing log statements use char counts not content — implementation must maintain this. Approved with non-blocking caution on log hygiene in new code paths.

## 2026-04-08 — PR #128 (docs: release and transcription troubleshooting notes)
Documentation-only PR with no linked planning issue. Blocked per protocol. All other roles also have `needs-*` labels — first pass. Docs content covers post-release verification, auto-release scope, AssemblyAI streaming notes, AX deferred readiness checks. Low inherent security risk but protocol requires linked issue before approval.

## 2026-04-08 — Issue #276: No action (MCP auth gap)
All GitHub MCP reads returned empty arrays for issue #276 on this private repo. Consistent with documented pattern. Took no action; waiting for re-trigger with valid context.
