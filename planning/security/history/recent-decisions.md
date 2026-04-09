# Recent Decisions

## Archived (pre-2026-04-07)
- `planning/*` branches unprotected; GITHUB_TOKEN commits acceptable.
- Workflow permissions: `permissions: {}` top-level, least-privilege job overrides. Fork guard required on PR workflows.
- Merge-readiness must be label-state-driven, not comment-parsed.
- Contents API writes produce `verified: false` on strict repos — prefer workflow commit signing.
- Persona/memory files on `planning/*` branches are low risk (isolated, no code execution).
- HUD fields must use categorical labels, not raw API error bodies.
- Issue #174: Approved. Label-state-only decision; permissions `contents: read`, `issues: write`, `pull-requests: write`.

## 2026-04-07 — MCP auth gap pattern (issues #223, #214, #201; PRs #247, #215, #184, #166, #246, #265)
All GitHub MCP reads returned empty arrays on this private repo. Took no action in each case. **Pattern: when MCP returns empty, do not approve; wait for re-trigger.**

## 2026-04-08 — Issue #270: Approved (iOS transcription text persistence fix)
Self-contained local state management fix in `iOSLiveTranscriber.swift`. No new permissions, no network flows, no credentials. Trust boundary unchanged. Existing log statements use char counts not content — implementation must maintain this.

## 2026-04-09 — Issue #270 retriggered (MCP auth gap)
All GitHub MCP reads returned empty arrays for issue #270 re-trigger (comment-id 4212471028). Prior stance (approved 2026-04-08) unchanged. Took no action.
