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

## 2026-03-25 — Issue #162 (plan-linked PR review lane)
Approved on first review. Scope is CI/workflow automation — no user data or secrets. Four implementation guardrails noted: (1) validate Plan issue number against actual approval labels, not just parse; (2) use `pull_request` not `pull_request_target` for fork PRs; (3) ready-to-merge label writable by workflow only; (4) prompt injection defence in PR review agents. Prior PR #161 implementation already addressed most of these.
