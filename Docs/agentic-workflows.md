# GitHub Agentic Workflows Setup

This repository is configured for GitHub Agentic Workflows (`gh aw`) using Copilot as the engine.

## Baseline repository setup

The repository was initialised with `gh aw init`, which added:

- `.gitattributes` to mark generated `.lock.yml` files
- `.github/agents/agentic-workflows.agent.md` as the gh-aw dispatcher agent
- `.github/workflows/copilot-setup-steps.yml` for Copilot Agent environment setup
- `.vscode/settings.json` and `.vscode/mcp.json` for local authoring support

Agentic workflow action pins are tracked through `.github/aw/actions-lock.json`, and generated gh-aw workflow outputs should be treated as derived files.

The required GitHub Actions secret is:

- `COPILOT_GITHUB_TOKEN`

Recommended configuration:

- required: a fine-grained personal access token (`github_pat_...`) with the `Copilot Requests` permission enabled
- not supported: OAuth tokens from the GitHub CLI app / Copilot CLI app (`gho_...`)
- not supported: classic personal access tokens (`ghp_...`)
- current repo pin: Copilot-engine workflows are explicitly pinned to GitHub Copilot CLI `1.0.21`, matching the current upstream known-good runtime

### Troubleshooting Copilot failures

Two failure classes look similar in Actions, but need different fixes:

- **Validation failure in `Validate COPILOT_GITHUB_TOKEN secret`** means the repository secret is the wrong token type. `COPILOT_GITHUB_TOKEN` must be a fine-grained PAT (`github_pat_...`), not `gho_...` or `ghp_...`.
- **Agent failure after successful token validation** means auth is probably fine and the next thing to inspect is the Copilot runtime itself. In this repository, the key signal was the agent process exiting with code `1` and zero stdout/stderr after installing the pinned Copilot CLI version.

When triaging, check the latest run history before changing the secret: a later bad token can mask an earlier runtime regression.

## Standard workflows installed

These catalogue workflows were added from `githubnext/agentics` and compiled into lock files:

- `daily-repo-status` — posts a daily repository status issue
- `daily-doc-updater` — proposes documentation updates as PRs
- `daily-test-improver` — improves tests and test coverage over time
- `daily-perf-improver` — proposes performance improvements over time
- `repository-quality-improver` — raises focused quality-analysis issues
- `ci-doctor` — investigates failures in the installed automation workflows
- `agentics-maintenance` — generated maintenance workflow for expiring agentic outputs
- `verify-basics` — lightweight push/manual smoke test for validating the Copilot-backed gh-aw path in this repository

We originally installed the stock `issue-triage` workflow too, but removed it after the overlap assessment: Product validation is now the first intake gate, so a separate anonymous triage step only added churn.

## Issue planning team

New issues enter a collaborative planning flow driven by GitHub comments and labels.

### Roles

The team consists of:

- **Alex Hale** (`Product`) — represents user value and product direction
  - signature habits: asks some version of "who is this really for?", keeps a quiet scope graveyard, and leaves a crisp path back to "yes"
- **Priya Shah** (`Security`) — reviews trust boundaries, auth, data handling, and abuse cases
  - signature habits: starts at the trust boundary, keeps a trust-debt ledger, and dates the threat sketch that changed the team's mind
- **Theo Quinn** (`Performance`) — reviews latency, resource cost, and measurement expectations
  - signature habits: asks for the metric first, keeps a baseline notebook, and immediately wants the hot path named
- **Casey Doyle** (`Code Quality`) — reviews maintainability, testing, support burden, and documentation quality
  - signature habits: names the failure mode before the fix, watches for surprise surface area, and prefers repair notes over drama
- **Morgan Reed** (`Architecture`) — reviews boundaries, sequencing, coupling, and rollout shape
  - signature habits: sketches boxes and arrows mentally, asks what breaks if a layer disappears, and keeps an allowed-seams map
- **Jordan Park** (`Reliability`) — reviews deployment safety, rollback plans, monitoring, and failure modes
  - signature habits: always asks for the rollback plan, keeps a blast radius map, and prefers boring deployment patterns over clever ones
- **Riley Tan** (`Design`) — reviews visual quality, M&S design standard alignment, accessibility, and responsive layout
  - signature habits: says "let me sketch this out…" before describing layouts, keeps a mental library of M&S design patterns, and believes in "show don't tell" with screenshot-based verification
- **Sam Chen** (`Engineering Manager`) — challenges weak cross-role reasoning and leaves the final coherence sign-off for issue planning
  - signature habits: asks "what would need to be true for everyone to approve?", names the seam between two good-but-conflicting ideas, and re-checks the whole thread after specialist replies land

Each role has:

- its own named Copilot custom agent file in `.github/agents/`
- its own workflow in `.github/workflows/`
- its own `repo-memory` branch under `planning/<role>`

The role memories capture each teammate's stable identity, recurring viewpoints, verified repository context, issue-specific decisions, and long-term heuristics so future reviews build on prior product and engineering thinking.

Each role memory should keep seven compact files or areas on its `planning/<role>` branch:

- `persona.md` — the stable name, signature habits, and earned quirks for that role in this repository
- `principles.md` — stable heuristics for that role
- `team-dynamics.md` — observed interaction patterns with other roles across issues
- `repository-context.md` — verified repo facts that repeatedly matter during planning and implementation review
- `issues/<issue-number>.md` — the live stance and resolved blockers for a specific issue
- `pull-requests/<pr-number>.md` — the PR review stance, implementation drift, approved deviations, and merge notes for a specific pull request
- `history/recent-decisions.md` — durable decisions and learnings

On repositories with stricter branch protections, the planning setup is only operationally complete once workflow-driven memory updates can still land on `planning/<role>`. If the repository requires signed commits on all branches, either exempt `planning/*` or configure workflow commit signing up front.

### Workflows

Custom planning and plan-review workflows added in this repository:

- `issue-product-validation` — Alex Hale (`Product`) handles the first intake pass and decides whether the issue fits this repository before full planning is allowed to start
- `issue-product-validation-agentic-follow-up` — dispatches Product validation for issues created by agentic workflow runs, because GitHub does not emit a normal `issues.opened` event when those issues are raised with `GITHUB_TOKEN`
- `issue-planning-auto-start` — detects maintainer-authored issues that reached `triage:product-fit` and dispatches planning automatically without waiting for an extra maintainer comment
- `issue-planning-command` — accepts an authorised `/doit` command even when it appears inside a longer maintainer comment, seeds planning state, and posts the kickoff comment that starts full planning with any surrounding text carried over as context
- `issue-planning-kickoff` — seeds the planning labels and explains the issue-planning flow after `/doit`
- `issue-ready-to-pr` — implements an approved issue plan once `planning:ready-for-dev` lands and opens a pull request with `Plan issue: #<number>` in the body
- `issue-planning-bot-follow-up` — deterministic dispatcher that re-queues the other reviewers when a bot-authored planning comment lands
- `issue-planning-product`
- `issue-planning-security`
- `issue-planning-performance`
- `issue-planning-quality`
- `issue-planning-architecture`
- `issue-planning-reliability`
- `issue-planning-design`
- `issue-planning-em` — Engineering Manager cross-role challenger and sign-off reviewer for issue planning
- `issue-planning-ready-check` — manual agentic audit for a specific issue
- `issue-planning-reconcile` — deterministic label reconciler that runs after role workflows finish
- `issue-planning-synthesis` — posts a unified team summary after all seven roles have weighed in, highlighting agreements, tensions, guardrails, and an implementation brief
- `pr-plan-review-kickoff` — seeds the PR plan-review labels and explains the implementation review flow
- `pr-plan-review-bot-follow-up` — deterministic dispatcher that re-queues the other reviewers when a bot-authored PR plan-review comment lands
- `pr-plan-review-product`
- `pr-plan-review-security`
- `pr-plan-review-performance`
- `pr-plan-review-quality`
- `pr-plan-review-architecture`
- `pr-plan-review-design`
- `pr-plan-review-rate-limit-retry` — reruns a PR plan-review workflow with backoff when the Copilot agent fails only because of a transient model rate limit
- `issue-agent-retry` — reruns only the failed jobs in failed issue-planning and `Issue Ready to PR` workflow runs when the failing job is the agent job, so transient Copilot runtime failures do not leave issues stuck
- `pr-plan-review-ready-check` — manual agentic audit for a specific pull request
- `pr-plan-review-reconcile` — deterministic label reconciler that runs after PR review workflows finish

### Labels

Issue intake is tracked with labels:

- `triage:product-fit`
- `triage:needs-clarification`
- `triage:out-of-scope`

Legacy issues may still carry `triage:pending-product-validation`, but new intake starts directly with Product validation rather than a separate pending label.

Planning state is tracked with labels:

- `planning:in-discussion`
- `planning:ready-for-dev`
- `planning:needs-product`
- `planning:needs-security`
- `planning:needs-performance`
- `planning:needs-quality`
- `planning:needs-architecture`
- `planning:needs-reliability`
- `planning:needs-design`
- `planning:product-approved`
- `planning:security-approved`
- `planning:performance-approved`
- `planning:quality-approved`
- `planning:architecture-approved`
- `planning:reliability-approved`
- `planning:design-approved`

PR implementation review state is tracked with labels:

- `plan-review:in-discussion`
- `plan-review:ready-to-merge`
- `plan-review:needs-product`
- `plan-review:needs-security`
- `plan-review:needs-performance`
- `plan-review:needs-quality`
- `plan-review:needs-architecture`
- `plan-review:needs-design`
- `plan-review:product-approved`
- `plan-review:security-approved`
- `plan-review:performance-approved`
- `plan-review:quality-approved`
- `plan-review:architecture-approved`
- `plan-review:design-approved`

### Normal operating flow

1. A new issue opens.
2. `Issue Product Validation` acts as the first intake gate and reviews the issue from the Product lens.
3. Alex Hale (`Product`) either:
   - marks it `triage:product-fit`,
   - asks for more detail with `triage:needs-clarification`, or
   - marks it `triage:out-of-scope`.
4. Maintainers can answer Product's questions in-thread or edit the issue until Product validation converges.
5. Once `triage:product-fit` is present, maintainer-authored issues are auto-dispatched into planning. For issues opened by someone without repository write access, a repository writer can still comment `/doit` on the issue. The command can stand alone or appear inside a longer maintainer note; any other text in that comment is carried into planning as context. If `Issue Product Validation` cannot safely verify live issue state, it should not guess from memory alone; a maintainer can recover explicitly by confirming the issue, applying `triage:product-fit`, and then using `/doit` or dispatching `Issue Planning - Command`.
6. `Issue Planning - Auto Start` scans for maintainer-authored Product-fit issues and dispatches `Issue Planning - Command` with an automatic handoff when no extra maintainer comment is needed.
7. `Issue Planning - Command` verifies that the initiating maintainer has write access, clears the intake labels, applies the `planning:*` labels, and posts the `### 🗂️ Planning Kickoff` comment.
8. `Issue Planning - Kickoff` remains available as the manual reset and re-entry path when maintainers want to restart planning explicitly.
9. The eight named teammates now join the thread, but the specialist lane is sequenced rather than parallel:
   - Alex Hale (`Product`)
   - Priya Shah (`Security`)
   - Theo Quinn (`Performance`)
   - Casey Doyle (`Code Quality`)
   - Morgan Reed (`Architecture`)
   - Jordan Park (`Reliability`)
   - Riley Tan (`Design`)
   - Sam Chen (`Engineering Manager` — leaves the final cross-role sign-off or challenges specific roles to reply)
10. Planning starts with Alex Hale (`Product`) only. Once the active specialist either approves or finishes its questions, the bot-follow-up dispatcher advances the issue to the next pending specialist lane in this order: Product → Security → Performance → Code Quality → Architecture → Reliability → Design.
11. Maintainers answer the active role's unresolved questions in-thread. Normal issue edits and maintainer comments only wake the current active specialist lane; later specialists wait their turn instead of piling on extra questions. `Issue Planning - Bot Follow Up` handles that requeue explicitly for maintainer clarifications so the next review step does not depend on a raw `issue_comment` agent run noticing the latest answer in time.
12. Alex Hale (`Product`) and Sam Chen (`Engineering Manager`) are expected to answer from repo memory, thread context, and sensible bounded assumptions whenever they can. They should escalate back to maintainers only when the remaining choice would materially change scope, risk, or ownership and the thread still lacks enough evidence for a good decision.
13. After the seven specialist approvals are complete, Sam Chen reads the thread as the cross-role challenger and either signs off or leaves a parseable `### 👔 Engineering Manager` comment with `Decision: challenge` and `Reply requested from: ...`.
14. When Sam challenges specific roles, the bot-follow-up dispatcher routes those reply requests back one named role at a time so that each challenged reviewer can finish its follow-up before the next reply lane opens.
15. If a maintainer explicitly asks a named role to respond, or Sam explicitly names a role in `Reply requested from: ...`, that role should leave a visible follow-up comment even if its approval label stays unchanged.
16. If a maintainer correction or verified repository fact disproves an earlier assumption, reviewers should revisit any approval that depended on it rather than leaning on older labels or comments as if the corrected concern were already resolved.
17. Role approval labels accumulate as concerns are resolved.
18. `Issue Planning - Reconcile State` normalises the pending labels and applies `planning:ready-for-dev` only when all seven specialist approvals are present and Sam's latest Engineering Manager decision is `approved` on the current thread state.
15a. `Issue Planning - Synthesis` is dispatched automatically by the reconciler when an issue reaches `planning:ready-for-dev`. It reads all seven role comments plus Sam's challenge/sign-off comments and posts a `### 🤝 Planning Team Summary` with agreements, open tensions, guardrails, and an implementation brief.
17. `Issue Planning - Reconcile State` also dispatches `Issue Ready to PR`.
18. `Issue Ready to PR` attempts the implementation automatically and opens a pull request that includes `Plan issue: #<issue-number>` in the PR body, ideally alongside `Closes #<issue-number>`.
19. `PR Plan Review - Kickoff` first checks whether the PR is only agentic-workflow maintenance (`.github/workflows/**`, `.github/aw/**`, `.github/agents/**`, `.github/copilot-instructions.md`, `Docs/agentic-workflows.md`, `.vscode/*`, `.gitattributes`). Those infra/runtime PRs are kept out of the specialist PR review lane and rely on the normal verification checks instead.
20. For implementation PRs, `PR Plan Review - Kickoff` then checks that the PR links exactly one issue that is already `planning:ready-for-dev`. If that seam is missing or not ready, it leaves one `### 🛂 Plan Review Blocked` comment and keeps the PR out of the active `plan-review:*` lane.
21. When the linked plan is valid, `PR Plan Review - Kickoff` seeds the `plan-review:*` labels and posts the kickoff comment.
22. `PR Plan Review - Kickoff Dispatch` then explicitly dispatches the six PR reviewer workflows after a successful kickoff so the initial review round starts even though bot comments do not emit reliable follow-up webhooks.
23. Routine Renovate PRs and agentic-workflow maintenance PRs are excluded from that automatic PR specialist fan-out by default. They stay on the standard verification lanes plus the relevant maintenance/fix path unless a maintainer explicitly chooses a deeper review route.
24. The PR reviewers discuss the pull request in thread, reply to each other when concerns intersect, and revisit approvals when new commits or corrections materially change the implementation.
25. `PR Plan Review - Reconcile State` normalises the pending PR labels and applies `plan-review:ready-to-merge` once all PR review approvals are present.

Note: the Engineering Manager role currently participates only in issue planning. PR plan review still has six specialist roles (Product, Security, Performance, Quality, Architecture, Design) and does not yet use an EM challenge loop.

The live issue ready-state reconciliation is handled by `Issue Planning - Reconcile State` because bot-applied labels do not reliably trigger another agentic workflow run. For the same reason, `Issue Planning - Auto Start` is a conventional workflow that scans for maintainer-authored `triage:product-fit` issues and explicitly dispatches `Issue Planning - Command` rather than relying on a bot-applied label event to fan out. That same reconcile step now dispatches `Issue Ready to PR` explicitly when an issue first becomes `planning:ready-for-dev`. Bot-to-bot planning follow-ups are handled by `Issue Planning - Bot Follow Up`, which now also understands parseable EM challenge comments and routes replies to the named role workflows. The issue role workflows themselves keep `github-actions` in `skip-bots` to avoid self-loops.

PR follow-ups are handled by `PR Plan Review - Bot Follow Up`, and `PR Plan Review - Reconcile State` owns the live `plan-review:ready-to-merge` transition. If a workflow cannot see the live issue or PR context clearly enough to verify the state, it should keep the thread open rather than guessing. `PR Plan Review - Rate Limit Retry` exists as the safety net for transient Copilot capacity failures: if a PR plan-review workflow fails only because the agent hit a rate limit, the repository waits briefly and reruns that workflow automatically rather than leaving the PR stuck. `Issue Agent Retry` provides the same kind of safety net for issue planning and `Issue Ready to PR` when the failing job is the agent job rather than conventional setup or reconciliation logic.

Important implementation detail: comments created with the default `GITHUB_TOKEN` do not emit fresh `issue_comment` events for other workflows to consume, so comment-based fan-out is not reliable on its own. In this repository the durable fan-out paths are explicit `workflow_dispatch` calls and `workflow_run`-triggered reconcilers, not bot comments pretending to be a second webhook.

The same applies to issues created by agentic workflow runs: GitHub does not emit a fresh `issues.opened` event for downstream workflows when the issue was opened with `GITHUB_TOKEN`. This repository therefore uses `Issue Product Validation - Agentic Follow Up` to look for new bot-authored issue outputs and dispatch `Issue Product Validation` explicitly.

### How team personalities build memory

Each named reviewer has a stable identity and an evolving repository memory:

- `persona.md` keeps the stable name, signature habits, and only the quirks that have been earned through repeated repository history
- `principles.md` captures recurring judgement patterns
- `repository-context.md` stores verified facts that repeatedly matter to that role
- `history/recent-decisions.md` records the calls that changed future judgement
- issue and PR files capture the live stance, then graduate lasting lessons back into the durable files

The rule is simple: names stay stable, judgement improves, and quirks only deepen when the memory shows they are genuinely part of how that teammate now works.

### When to use `/doit`

`/doit` is the manual maintainer handoff from Product validation into full planning. Use it only when all of these are true:

- the issue already has `triage:product-fit`
- someone with repository write access is making the comment
- the issue is ready for Alex, Priya, Theo, Casey, Morgan, Jordan, and Riley to start the full planning discussion (with Sam facilitating) rather than still needing Product clarification

Do not use `/doit` while the issue still lacks `triage:product-fit`, or while it is in `triage:needs-clarification` or `triage:out-of-scope`. In those states, continue the Product discussion in-thread or update the issue until Product validation changes.

`/doit` does not need to be the whole comment. A maintainer can write a short note such as scope guidance, a preferred option, or an answer to an open question in the same comment. The workflow will treat `/doit` as the command and carry the surrounding text into the kickoff comment as planning context.

Once `/doit` is accepted, the issue moves into `planning:*` labels, the kickoff comment starts the sequential eight-role discussion, and maintainers should answer the active role's open questions in-thread until that role converges and the next lane unlocks. If the `/doit` comment included extra text, that text is quoted into the kickoff comment as maintainer planning context. Alex and Sam should still try to settle product and cross-role questions from memory, repo facts, and sensible defaults before they escalate. Maintainer-authored issues that reach `triage:product-fit` can skip this comment because `Issue Planning - Auto Start` will dispatch planning automatically. After the seven specialist approvals are present, Sam may still leave a `Decision: challenge` comment with `Reply requested from: ...` to force a specific role response before the plan can converge. When the seven specialist approvals are present and Sam's latest decision is `approved`, `Issue Ready to PR` will attempt the implementation automatically. The resulting pull request should include `Plan issue: #<issue-number>` in the body so the PR review lane can compare the implementation against the approved plan.

### Portable rollout pattern for other repositories

Use this rollout order when you add the planning team elsewhere:

1. Prove the Copilot-backed path first with a minimal verifier workflow. Do not assume secret validation alone proves inference works.
2. Make Product validation the first gate for new issues, then add `issue-planning-command`, the issue-planning kickoff, bot-follow-up dispatcher, seven role workflows plus the EM challenge/sign-off workflow, ready-check, and reconcile workflow, plus the matching PR plan-review kickoff, bot-follow-up dispatcher, six role workflows, ready-check, and reconcile workflow.
3. Name the team up front. Give each role a human name and 2-3 signature habits in `.github/agents/planning-<role>.agent.md`, and keep the role label explicit in comments.
4. Create the intake, planning, and `plan-review:*` labels before live testing so all three stages have stable targets.
5. Seed all eight `planning/<role>` memory branches up front (product, security, performance, quality, architecture, reliability, design, em) by creating `persona.md`, `principles.md`, `repository-context.md`, and `history/recent-decisions.md`, plus the `issues/` and `pull-requests/` directories, rather than waiting for first use.
6. Before expecting repo-memory writes to work, verify that `planning/*` can accept workflow-created commits. On repositories with required signed commits, either provide an approved `planning/*` exemption or configure workflow commit signing before live rollout.
7. Retest on at least one realistic issue and one workflow-health issue. Use the realistic issue as the main proof. For workflow-health issues, ask a concrete portability or design question; otherwise reviewers may collapse into one-shot approvals instead of a real discussion.
8. Prove the intake gate as well as the planning gate: a new issue should get a Product fit review directly on open, Product should either validate or challenge its fit, maintainer-authored Product-fit issues should auto-start planning, and `/doit` from an authorised maintainer should remain the manual path for other issues.
9. After an issue reaches `planning:ready-for-dev`, prove that `Issue Ready to PR` can open a small same-repo pull request automatically with `Plan issue: #<issue-number>` in the body, and that the PR review lane reaches `plan-review:ready-to-merge` with real back-and-forth between roles.
10. Keep `Issue Planning - Ready Check` and `PR Plan Review - Ready Check` as manual audit paths, and let the reconcile workflows own the live label normalisation.
11. On strict repositories, do not declare the rollout complete until both the issue-planning and PR plan-review workflows can persist their role memory using an approved write path.

### Resetting or retesting planning and plan review

On the default branch, new issues enter `Issue Product Validation` automatically. Maintainer-authored issues that reach `triage:product-fit` now start planning automatically, while `/doit` from an authorised repository writer remains the manual start path for other issues and still carries any extra text in that comment into the kickoff comment as planning context. `Issue Planning - Reconcile State` keeps the planning labels aligned after each role workflow completes and dispatches `Issue Ready to PR` when the issue first becomes `planning:ready-for-dev`. `PR Plan Review - Reconcile State` does the same for pull requests.

## Operational workflows

These workflows keep the agentic system healthy over time:

### Memory curation

`memory-curator` runs bi-weekly (or on demand) and curates each role's memory:

- Graduates recurring patterns from `recent-decisions.md` to `principles.md`
- Prunes stale one-off decisions older than 60 days
- Removes redundant or contradictory principles
- Cleans up closed issue files once learnings are captured
- Cross-pollinates insights between roles when one role discovers something another needs

### Repository context refresh

`repository-context-refresh` runs weekly (or on demand) and keeps each role's `repository-context.md` current with verified codebase facts: tech stack, module structure, deployment shape, and configuration.

### Improvement coordination

`improvement-coordinator` runs daily before the test/perf/doc improvement agents and checks for:

- Duplicate or overlapping improvement PRs
- Stale improvement PRs open for more than 5 days
- Failed improvement PRs that need attention
- Creates a coordination report issue only when action is needed

### Stale failure cleanup

`stale-issue-cleanup` runs weekly and closes automated `[aw] ... failed` issues that are older than 7 days with no human engagement, provided the underlying workflow has had successful runs since. This prevents noise from transient failures accumulating.

### Shared team memory

A `planning/team` memory branch holds cross-cutting knowledge used by the synthesis agent:

- `recurring-tensions.md` — patterns of disagreement that recur across multiple issues
- `resolved-patterns.md` — standard guardrails the team applies consistently
- `issues/<issue-number>.md` — the synthesis for each discussed issue

## Known failure patterns and remediation

Agent workflows occasionally fail with these known patterns:

### Cache-related failures (~60% of incidents)

- **"Unable to download artifact: cache-memory not found"** — The gh-aw cache for a workflow has expired (7-day TTL) or the workflow is running for the first time. Resolves automatically on the next successful run.
- **"Repo-Memory Push Failed: digest-mismatch"** — Corrupted or incomplete cached state. Clear the Actions cache for the affected workflow and re-run.

**Fix**: Clear all Actions caches and re-run the affected workflows:

```bash
# List caches
gh api /repos/crmitchelmore/justspeaktoit/actions/caches --jq '.actions_caches[] | "\(.id) \(.key)"'

# Delete a specific cache by ID
gh api -X DELETE /repos/crmitchelmore/justspeaktoit/actions/caches/<id>
```

### Agent output failures (~30% of incidents)

- **"Error reading agent output file: ENOENT"** — The agent process crashed before writing its output. Usually cascades from a cache restoration failure. The gh-aw framework has no graceful fallback for this case.

**Mitigation**: These are framework-level issues that resolve when the cache is healthy. The `stale-issue-cleanup` workflow will auto-close failure issues older than 7 days with no human engagement.

### Structural prevention

- The `improvement-coordinator` workflow checks for conflicting improvement PRs before daily agents run.
- The `stale-issue-cleanup` workflow prevents noise from transient failure issues accumulating.
- The `agentics-maintenance` workflow handles expiring stale agent-created issues and PRs on a 6-hour schedule.

### Resetting or retesting planning and plan review

On the default branch, new issues enter `Issue Product Validation` automatically. Maintainer-authored issues that reach `triage:product-fit` now start planning automatically, while `/doit` from an authorised repository writer remains the manual path for other issues and still carries any extra text in that comment into the kickoff note as planning context. `Issue Planning - Reconcile State` keeps the planning labels aligned after each role workflow completes, and `PR Plan Review - Reconcile State` does the same for pull requests.

Before merge, or when manually re-running either stage, use `workflow_dispatch` with an issue number or pull request number. For example:

```bash
gh workflow run issue-product-validation.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-kickoff.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-product.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-security.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-performance.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-quality.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-architecture.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-reliability.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-design.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-em.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-reconcile.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-ready-check.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-ready-to-pr.lock.yml --ref <branch> -f issue_number=123

gh workflow run pr-plan-review-kickoff.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-product.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-security.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-performance.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-quality.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-architecture.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-design.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-reconcile.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-ready-check.lock.yml --ref <branch> -f pr_number=123
```

Use `Issue Planning - Reconcile State` for the live issue label repair path and `Issue Planning - Ready Check` as a manual issue audit.

Use `PR Plan Review - Reconcile State` for the live PR label repair path and `PR Plan Review - Ready Check` as a manual PR audit.

For workflows that only exist on a feature branch, `gh workflow run --ref <branch>` can be unreliable. Prefer a push-trigger smoke test before merge, then re-run Product validation, issue-planning, and PR plan-review workflows again on the default branch once they land.

To restart intake for an existing issue, re-run `Issue Product Validation`. To restart full planning for an intake-approved issue, let `Issue Planning - Auto Start` pick it up automatically if the issue author has repository write access, use `/doit` again (optionally with a short maintainer note that will be carried into kickoff), or manually dispatch `Issue Planning - Kickoff`. To retry automatic implementation for an already-approved issue, manually dispatch `Issue Ready to PR`. To restart PR plan review for an existing pull request, re-run `PR Plan Review - Kickoff` or push a new commit after clarifying the linked plan.

#### Recovering from stale PR plan-review comments

If a pull request is opened before its approved planning issue is linked in the body, the first PR review pass may leave stale comments that only reflect the missing-plan state.

Use this recovery path:

1. Edit the PR body so it includes `Plan issue: #<issue-number>`, ideally alongside `Closes #<issue-number>` or an equivalent closing reference.
2. If the thread still reflects the old state, add one maintainer clarification comment that points reviewers at the approved issue and answers any open questions that were resolved outside the first pass.
3. Re-run `PR Plan Review - Kickoff` or the affected `pr-plan-review-<role>.lock.yml` workflows so the same six reviewers evaluate the updated PR state.
4. Let `PR Plan Review - Reconcile State` normalise the labels back to `plan-review:ready-to-merge` once all six approvals converge again.

This recovery path re-runs the normal plan-review gate; it does not bypass or weaken it. PR plan-review role workflows should only respond on pull-request threads, while issue-planning threads should stay limited to the eight issue-planning participants (seven specialist reviewers plus the EM challenge/sign-off role).

#### Implementation note: PR plan-review trigger guard

PR plan-review `issue_comment` workflows guard entry by checking whether the issue HTML URL contains `/pull/` rather than relying on `issue.pull_request != null`. The latter can be `null` or absent for certain event shapes (notably plain issue comments), which caused issue comments to incorrectly trigger PR review workflows and attach stray `plan-review:*` labels to issues. The URL shape check (`html_url` contains `/pull/`) is the durable guard.

#### Plan PR CI-fix dispatch: fork detection and broader plan PR matching

The `plan-pr-ci-fix-dispatch` workflow now:

- Skips PRs that originate from a fork repository (checks `head.repo.full_name !== repo`) to prevent dispatching fix agents to external contributor branches.
- Identifies a PR as a plan PR when the title starts with `[Plan]`, the PR carries an `automation` label, or the body contains `Plan issue: #` — previously only the title check was applied.

#### Agentic self-improver: recency check before acting

Before making any changes, `agentic-improvement` now runs a recency check:

1. Run `git log --oneline --since='2 hours ago' -- .github/ Docs/ README.md` to inspect recent workflow-system commits.
2. Review recent outcomes for the configured target workflows.
3. If nothing meaningful changed and no new failures, drift, or duplicate-noise patterns appeared, exit without making changes to avoid no-op churn.
