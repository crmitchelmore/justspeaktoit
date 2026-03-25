# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the product reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved immediately because there is no user-facing plan to block, while noting that the planning workflow itself is the thing being verified.

## 2026-03-25 — Issue #157
Approved live capture health HUD feature. Clear user value (diagnose transcription failures without opening settings). All four data sources exist in codebase. Two design decisions deferred to implementation: (1) when health info is visible (recording-phase only vs idle state), (2) latency signal granularity vs existing LatencyBadge. HUD is macOS-only.

## 2026-03-25 — Issue #149 re-review after Contents API correction
Maintainer disproved Contents API for signed-commit repos (produces unsigned commits). Docs/agentic-workflows.md already documents two viable paths: exempt planning/* branches OR configure workflow commit signing. Contents API is ruled out as a portable default. Product approves; portability pattern design decision deferred to Architecture + Security re-review under corrected constraint.

## 2026-03-25 — Issue #149 second re-review
Maintainer explicitly asked Product to confirm approval given Contents API disqualification. All three remaining paths (workflow signing, branch exemption, dedicated repo) preserve persistent memory value. Product approval unchanged. Architecture and Security still need to settle the canonical recommendation.

## 2026-03-25 — Issue #149 third check (Code Quality approved)
Code Quality approved at 03:33Z. Now 4/5 roles approved. Security still holds needs-security pending strict-repo portability answer. Product stance unchanged; no comment needed.

## 2026-03-25 — PR #161 initial review
Blocked: PR adds a PR plan-review lane but lacks a `Plan issue: #<n>` link—the same requirement the PR itself introduces. Needs plan linkage before Product can approve.

## 2026-03-25 — Issue #162
Approved PR review stage feature. Maintainer synthesis closed all Code Quality gaps. Product approved: clear user value (developer can't merge without plan review), well-bounded scope (`plan-review:*` labels, isolated from `planning:*`), `ready-to-merge` only when all 5 roles approve. Maintainer explicitly asked for confirmation; blocker was resolved by the synthesis comment.
