# Recent Decisions

## Summary of foundational patterns (issues #149, #157, #162, #174, #175, PRs #161, #175, #177, #181)
- `planning/*` branches: GITHUB_TOKEN commits acceptable, unprotected.
- Workflow permissions: `permissions: {}` top-level, least-privilege job overrides. Fork guard required.
- Merge-readiness: label-state-driven only (no comment parsing).
- Contents API writes produce `verified: false` — prefer workflow commit signing.
- Persona/memory files on `planning/*` branches are low risk (isolated, no code execution).
- HUD fields: categorical labels, not raw API error bodies.

## 2026-04-07 — MCP auth gap pattern (PRs #247, #215, #184, #166, #246, #265; issues #223, #214, #201)
All GitHub MCP reads returned empty arrays on this private repo. Took no action in each case.
Pattern: when MCP returns empty, do not approve; wait for re-trigger.

## 2026-04-08 — Issue #270: Approved (iOS transcription text persistence fix)
Self-contained local state fix in `iOSLiveTranscriber.swift`. No new permissions, no network flows, no credentials. Trust boundary unchanged. Log statements use char counts not content — implementation must maintain this.

## 2026-04-08 — Issues #271, #276, #277, #283, #263: No action (MCP auth gap)
All GitHub MCP reads returned empty arrays. Consistent with documented pattern.

## 2026-04-08 — PR #282, PR #228: No action (MCP auth gap)
All GitHub MCP reads returned empty arrays. Consistent with documented pattern.

## 2026-04-09 — Issue #252: No action (MCP auth gap)
All GitHub MCP reads returned empty arrays for issue #252. Consistent with documented pattern.

## 2026-04-09 — PR #271: No action (MCP auth gap — PR review trigger)
Triggered by issue_comment (comment-id 4212471027). All MCP reads empty. Cannot evaluate trust boundaries, linked plan, labels, or draft status. No action taken.

## 2026-04-09 — Issue #283: Approved (missing SpeakCore import fix)
One-line compile fix: `import SpeakCore` added to `SpeakiOSApp.swift`. `OpenClawClient` already referenced at line 93; no new surface, permissions, or trust boundary change. All 6 other roles approved. Approved immediately after code verification. Final label: `planning:ready-for-dev`.

## 2026-04-09 — Issue #157: No action (MCP auth gap — workflow_dispatch re-trigger)
Triggered by workflow_dispatch. Both issue get and get_comments returned empty arrays. Prior approval from initial review already on record in issues/157.md. No action taken — cannot evaluate any new comments or label changes without live issue context.

## 2026-04-11 — PR #300: No action (PR already merged)
Triggered by issue_comment from coderabbitai[bot] (rate-limit warning, not a plan-review comment). PR was already merged at 2026-04-11T08:33:59Z. No plan-review labels, no kickoff comment. Rule applied: issue_comment trigger on merged PR → do nothing. Workflow-only changes (gh-aw v0.62.3→v0.67.4, new helper workflows, start_issue_planning.py, Reliability/EM/Design roles); security surface unchanged.
