# Recent Decisions

## 2026-03-25 — Foundational patterns (issues #149, #157, #162, PRs #161, #175, #177, #181)
- `planning/*` branches unprotected; GITHUB_TOKEN commits via `github-actions[bot]` acceptable.
- Workflow permissions: `permissions: {}` top-level, least-privilege job overrides. Fork guard required on all PR workflows.
- Merge-readiness must be label-state-driven, not comment-parsed.
- Contents API writes produce `verified: false` on strict repos — prefer workflow commit signing.
- Persona/memory files on `planning/*` branches are low risk (isolated, no code execution).
- HUD fields must use categorical labels, not raw API error bodies.

## 2026-03-25 — Issue #174: Approved (both blockers resolved by maintainer)
PR reconcile: label-state-only decision (no comment parsing for merge-readiness). Permissions: `contents: read`, `issues: write`, `pull-requests: write`. `issue_comment` trigger is idempotent nudge only. Atomic removal avoids double-fire window. Named persona files copied from career-framework — same isolation pattern, low risk.

## 2026-03-25 — PR #175 (port final career-framework agentic pattern)
Approved. Fork guard on all PR workflows, `permissions: {}` top-level with least-privilege job overrides, reconcile is label-state-only. No new attack surface.

## 2026-04-07 — MCP auth gap pattern (issues #223, #214, #201; PRs #247, #215, #184, #166, #246, #265)
All GitHub MCP reads returned empty arrays on this private repo. Took no action in each case. Pattern: when MCP returns empty, do not approve; wait for re-trigger.

## 2026-04-08 — Issue #270: Approved (iOS transcription text persistence fix)
Self-contained local state management fix in `iOSLiveTranscriber.swift`. No new permissions, no network flows, no credentials. Trust boundary unchanged. Existing log statements use char counts not content — implementation must maintain this.

## 2026-04-08 — PR #128 (docs: release and transcription troubleshooting notes)
Documentation-only PR with no linked planning issue. Blocked per protocol.

## 2026-04-08 — Issue #276: No action (MCP auth gap)
All GitHub MCP reads returned empty arrays for issue #276. Consistent with documented pattern. Took no action.

## 2026-04-08 — Issue #271: No action (MCP auth gap)
All GitHub MCP reads returned empty arrays for issue #271. Consistent with documented pattern. Took no action.

## 2026-04-08 — Issue #277: No action (MCP auth gap)
All GitHub MCP reads returned empty arrays for issue #277. Consistent with documented pattern. Took no action.
