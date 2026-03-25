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

## 2026-03-25 — Issue #162 review
Issue already had all five role approvals + ready-for-dev on workflow_dispatch review. No prior Product memory existed for this issue. Confirmed approval is appropriate: clear problem (plan-to-PR gap), specific requirements, testable guardrails (PR template, dispatch scope). Recorded issue memory; no comment needed.

## 2026-03-25 — PR #161 re-check (workflow_dispatch)
Product approval confirmed and label already present. PR has plan link (Plan issue: #162), which was the prior blocker. All roles approved except Code Quality (needs-quality still present). No product action needed; waiting on Quality.

## 2026-03-25 — Issue #174
Approved on issue open. Clear workflow/tooling issue to port the proven career-framework agentic workflow pattern. Well-scoped with named reference design and testable success criteria. No end-user product risk. Interesting meta-fact: this issue triggered the Product-validates-on-open gate, which is itself one of the success criteria of the issue.

## 2026-03-25 — Issue #174 maintainer clarification check
Maintainer provided detailed implementation contracts addressing Security (label-only reconcile decision, minimal permissions) and Code Quality (split smoke-test protocol). Product approval unchanged — clarifications don't affect product scope or user value. Security and Quality still need to re-review.

## 2026-03-25 — PR #175 initial review
Approved immediately. PR #175 ports the final career-framework agentic workflow pattern. Plan issue #174 is planning:ready-for-dev with all five roles approved. PR description maps directly to all 7 plan requirements. Live proof: this Product-validates-on-PR-open review is itself evidence that requirement 1 (Product validation at intake) is delivered. Supersedes PR #161 (intermediate shape); named explicitly in PR body.

## 2026-03-25 — Issue #176
Approved docs-only issue to document the default-branch proof pattern for agentic workflow changes. Evidence-backed pattern from PR #175: new workflow files on feature branches cannot be manually dispatched from main before merge. Clear scope (one note in `Docs/agentic-workflows.md`), concrete acceptance criteria, no implementation change.

## 2026-03-25 — PR #177 initial review
Approved immediately. Docs-only change to `Docs/agentic-workflows.md` replacing a vague sentence with a clear 3-step proof pattern. Plan issue #176 was approved; all three acceptance criteria delivered in diff. No scope drift.
