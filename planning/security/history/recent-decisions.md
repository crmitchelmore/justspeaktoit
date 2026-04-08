# Recent Decisions

## 2026-03-25 — Seeded role memory
Added `principles.md` and `repository-context.md` for the security reviewer so future planning discussions start with verified repository context.

## 2026-03-25 — Issue #149
Approved because the issue adds no new product attack surface and exists to verify that secret rotation restored automation.

## 2026-03-25 — Issue #157 (capture health HUD)
Approved. Low attack surface: all new HUD fields are categorical labels (permission bool, device name, provider name, latency bucket). Non-blocking caution: ensure health-state error text uses categorical labels, not raw provider API error bodies. HUDManager already exposes `subheadline` from raw `message` strings — implementation must guard this path.

## 2026-03-25 — Issue #149: Contents API correction

Live throwaway-branch test showed `PUT /repos/{owner}/{repo}/contents/{path}` produced `verified: false`, `reason: unsigned` here. Do not treat Contents API writes as a signed-commit-safe default. For strict repos, prefer workflow commit signing as the portable default, with branch exemption as a repo-local fallback when governance allows it.

## 2026-03-25 — Issue #149: Approved (signed-commit concern resolved)
`planning/*` branches are unprotected; GITHUB_TOKEN commits via `github-actions[bot]` are acceptable here. The prior blocker (Contents API PAT → `verified: false`) was hypothetical for strict repos and does not apply. Issue approved.

## 2026-03-25 — PR #161 (plan-review lane for PRs)
Blocked: no linked planning issue. Implementation looks clean (fork guard, least-privilege permissions, prompt injection defence in agent runtime). Primary blocker is governance — the PR that introduces the `Plan issue:` requirement doesn't include one itself.

## 2026-03-25 — PR #161 (first security comment)
Implementation is clean (fork guard, least-privilege, secrets redacted, comment-body via env var, bot dispatcher scoped to known headings). Blocked only on missing plan issue linkage. This is a bootstrapping PR—maintainer must add a `Plan issue:` reference to the approved planning issue or explicitly waive the requirement.

## 2026-03-25 — PR #161 follow-up (issue #162 found)
Issue #162 identified as the retroactive plan for PR #161. PR still blocked: body lacks `Plan issue: #162`, and issue #162 is not yet `planning:ready-for-dev` (needs product + quality). Security review stance unchanged.

## 2026-03-25 — PR #161 final state confirmed
All prior security blockers resolved: `Plan issue: #162` in PR body; issue #162 is `planning:ready-for-dev` with all five approvals. `plan-review:security-approved` already applied. Quality is the only remaining hold.

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

## 2026-03-26 — PR #186 (AgenTek planning team improvements)
Blocked on missing linked plan issue. Permissions and fork guards are consistent with established pattern. Stale-issue-cleanup auto-close (max 20/run) noted as meaningful irreversible action but appropriately scoped to `agentic-workflows` labelled issues with no human engagement.

## 2026-03-26 — PR #188 (add Riley Tan Design reviewer)
Blocked on missing linked plan issue. Same pattern as PR #186. Implementation is clean: `permissions: {}` top-level, least-privilege job overrides, fork guard in lock.yml, `COPILOT_GITHUB_TOKEN` usage consistent with established pattern. The new design workflows mirror existing role workflows exactly. Primary blocker is governance — missing `Plan issue: #<n>` in PR body. PR #188 also incorporates the AgenTek improvements from PR #186 (which was closed without merge for the same reason).

## 2026-03-26 — PR #191 (disable failure issue creation on all workflows)
Blocked on missing linked plan issue. The change itself is security-neutral: pure noise-reduction config (`GH_AW_FAILURE_REPORT_AS_ISSUE: false`) applied consistently to all 31 workflows. No permissions, trust boundaries, or auth changes. Blocker is governance only.

## 2026-04-07 — Issue #223: No access (private repo / MCP auth gap)
All GitHub MCP reads returned empty arrays. Could not access issue body, labels, or comments. Took no action. Security stance unset. If re-triggered with valid context, review from scratch.

## 2026-04-07 — Issue #214: No access (private repo / MCP auth gap)
All GitHub MCP reads returned empty arrays. Could not access issue body, labels, or comments. Took no action. Security stance unset. If re-triggered with valid context, review from scratch.

## 2026-04-07 — PR #247: No access (private repo / MCP auth gap)
All GitHub MCP reads returned empty arrays. Could not access PR body, diff, labels, linked plan, or comments. Took no action. Security stance unset. If re-triggered with valid context, review from scratch.

## 2026-04-07 — PR #215: No access (private repo / MCP auth gap)
All GitHub MCP reads returned empty arrays for PR #215. PR does not appear in the full PR list (which shows 175, 177, 181, 182, 186, 188, 189, 191, 225, 267 — no 215). Could not access PR body, diff, labels, linked plan, or comments. Took no action. Security stance unset. If re-triggered with valid context, review from scratch.

## 2026-04-07 — PR #184: No access (private repo / MCP auth gap)
All GitHub MCP reads returned empty arrays. PR #184 not found in open PR list. Could not access PR body, diff, labels, linked plan, or comments. Took no action — PR likely closed or merged. Security stance unset.

## 2026-04-07 — PR #166: Not a PR (issue_comment on issue #166)
GitHub context shows `pull-request-number` is empty. PR #166 does not appear in the open PR list. The `issue_comment` trigger fires on issue #166, which is a planning issue, not a PR. Per review protocol, took no action — the comment does not belong to a pull request.

## 2026-04-07 — PR #246: No access (private repo / MCP auth gap, likely not a PR)
GitHub context shows `issue-number: #246`, `pull-request-number: (empty)`. #246 not in open PR list. Direct PR/issue reads returned empty. Per `issue_comment` protocol, took no action — comment does not appear to belong to a pull request.

## 2026-04-07 — PR #265: Not a PR (issue_comment on issue #265)
GitHub context shows `pull-request-number` is empty. #265 does not appear in the open PR list (only #267 and #128 are open). The `issue_comment` trigger fires on issue #265, which is an issue, not a PR. Per review protocol, took no action — the comment does not belong to a pull request.

## 2026-04-07 — Issue #201: No access (private repo / MCP auth gap)
All GitHub MCP reads returned empty arrays. Could not access issue body, labels, or comments. Took no action. Security stance unset. If re-triggered with valid context, review from scratch.

## 2026-04-08 — PR #256: Not a PR (issue_comment on issue #256)
GitHub context shows `issue-number: #256`, `pull-request-number: (empty)`. #256 does not appear in the open PR list (only #267 and #128 are open). All direct reads returned empty. Per `issue_comment` protocol, took no action — the comment does not belong to a pull request.
