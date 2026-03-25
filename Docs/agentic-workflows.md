# GitHub Agentic Workflows Setup

This repository is configured for GitHub Agentic Workflows (`gh aw`) using Copilot as the engine.

## Baseline repository setup

The repository was initialised with `gh aw init`, which added:

- `.gitattributes` to mark generated `.lock.yml` files
- `.github/agents/agentic-workflows.agent.md` as the gh-aw dispatcher agent
- `.github/workflows/copilot-setup-steps.yml` for Copilot Agent environment setup
- `.vscode/settings.json` and `.vscode/mcp.json` for local authoring support

The required GitHub Actions secret is:

- `COPILOT_GITHUB_TOKEN`

## Standard workflows installed

These catalogue workflows were added from `githubnext/agentics` and compiled into lock files:

- `issue-triage` — triages new issues, adds a concise intake summary, and hands them to Product validation
- `daily-repo-status` — posts a daily repository status issue
- `daily-doc-updater` — proposes documentation updates as PRs
- `daily-test-improver` — improves tests and test coverage over time
- `daily-perf-improver` — proposes performance improvements over time
- `repository-quality-improver` — raises focused quality-analysis issues
- `ci-doctor` — investigates failures in the installed automation workflows

## Issue planning team

New issues enter a collaborative planning flow driven by GitHub comments and labels.

### Roles

The team consists of:

- Product — represents user value and product direction
- Security — reviews trust boundaries, auth, data handling, and abuse cases
- Performance — reviews latency, resource cost, and measurement expectations
- Code Quality — reviews maintainability, testing, and support burden
- Architecture — reviews boundaries, sequencing, coupling, and rollout shape

Each role has:

- its own Copilot custom agent file in `.github/agents/`
- its own workflow in `.github/workflows/`
- its own `repo-memory` branch under `planning/<role>`

The role memories capture recurring viewpoints, verified repository context, issue-specific decisions, and long-term heuristics so future reviews build on prior product and engineering thinking.

Each role memory should keep five compact files or areas on its `planning/<role>` branch:

- `principles.md` — stable heuristics for that role
- `repository-context.md` — verified repo facts that repeatedly matter during planning and implementation review
- `issues/<issue-number>.md` — the live stance and resolved blockers for a specific issue
- `pull-requests/<pr-number>.md` — the PR review stance, implementation drift, approved deviations, and merge notes for a specific pull request
- `history/recent-decisions.md` — durable decisions and learnings

On repositories with stricter branch protections, the planning setup is only operationally complete once workflow-driven memory updates can still land on `planning/<role>`. If the repository requires signed commits on all branches, either exempt `planning/*` or configure workflow commit signing up front.

### Workflows

Custom planning and plan-review workflows added in this repository:

- `issue-triage` — basic issue intake that leaves a concise triage summary, resets the intake state, and hands off to Product validation
- `issue-product-validation-dispatch` — deterministic dispatcher that starts Product validation for newly triaged issues
- `issue-product-validation` — Product checks whether the issue fits this repository before full planning is allowed to start
- `issue-planning-command` — accepts an authorised `/doit` comment and dispatches full planning
- `issue-planning-kickoff` — seeds the planning labels and explains the issue-planning flow after `/doit`
- `issue-planning-bot-follow-up` — deterministic dispatcher that re-queues the other reviewers when a bot-authored planning comment lands
- `issue-planning-product`
- `issue-planning-security`
- `issue-planning-performance`
- `issue-planning-quality`
- `issue-planning-architecture`
- `issue-planning-ready-check` — manual agentic audit for a specific issue
- `issue-planning-reconcile` — deterministic label reconciler that runs after role workflows finish
- `pr-plan-review-kickoff` — seeds the PR plan-review labels and explains the implementation review flow
- `pr-plan-review-bot-follow-up` — deterministic dispatcher that re-queues the other reviewers when a bot-authored PR plan-review comment lands
- `pr-plan-review-product`
- `pr-plan-review-security`
- `pr-plan-review-performance`
- `pr-plan-review-quality`
- `pr-plan-review-architecture`
- `pr-plan-review-ready-check` — manual agentic audit for a specific pull request
- `pr-plan-review-reconcile` — deterministic label reconciler that runs after PR review workflows finish

### Labels

Issue intake is tracked with labels:

- `triage:pending-product-validation`
- `triage:product-fit`
- `triage:needs-clarification`
- `triage:out-of-scope`

Planning state is tracked with labels:

- `planning:in-discussion`
- `planning:ready-for-dev`
- `planning:needs-product`
- `planning:needs-security`
- `planning:needs-performance`
- `planning:needs-quality`
- `planning:needs-architecture`
- `planning:product-approved`
- `planning:security-approved`
- `planning:performance-approved`
- `planning:quality-approved`
- `planning:architecture-approved`

PR implementation review state is tracked with labels:

- `plan-review:in-discussion`
- `plan-review:ready-to-merge`
- `plan-review:needs-product`
- `plan-review:needs-security`
- `plan-review:needs-performance`
- `plan-review:needs-quality`
- `plan-review:needs-architecture`
- `plan-review:product-approved`
- `plan-review:security-approved`
- `plan-review:performance-approved`
- `plan-review:quality-approved`
- `plan-review:architecture-approved`

### Normal operating flow

1. A new issue opens.
2. `issue-triage` leaves a basic triage summary, applies any obvious repository labels, and sets `triage:pending-product-validation`.
3. `Issue Product Validation - Dispatch` explicitly starts Product validation for issues that just entered triage.
4. `Issue Product Validation` reviews the issue from the Product lens and either:
   - marks it `triage:product-fit`,
   - asks for more detail with `triage:needs-clarification`, or
   - marks it `triage:out-of-scope`.
5. Maintainers can answer Product's questions in-thread or edit the issue until Product validation converges.
6. Once `triage:product-fit` is present, someone with repository write access comments `/doit` on the issue.
7. `Issue Planning - Command` verifies that the commenter has write access, clears the intake labels, applies the `planning:*` labels, posts the `### 🗂️ Planning Kickoff` comment, and explicitly dispatches the five planning reviewers.
8. `Issue Planning - Kickoff` remains available as the manual reset and re-entry path when maintainers want to restart planning explicitly.
9. Each issue reviewer comments in thread, asks focused follow-up questions, and bot-authored reviewer comments re-dispatch the other reviewers without letting a workflow react to its own comment directly.
10. Maintainers answer unresolved questions in-thread, and those direct maintainer comments trigger the issue reviewers as well.
11. If a maintainer explicitly asks a named role to respond, that role should leave a visible follow-up comment even if its approval label stays unchanged.
12. If a maintainer correction or verified repository fact disproves an earlier assumption, reviewers should revisit any approval that depended on it rather than leaning on older labels or comments as if the corrected concern were already resolved.
13. Role approval labels accumulate as concerns are resolved.
14. `Issue Planning - Reconcile State` normalises the pending labels and applies `planning:ready-for-dev` once all five approvals are present.
15. The implementer opens a pull request and includes `Plan issue: #<issue-number>` in the PR body, ideally alongside a closing reference such as `Closes #<issue-number>`.
16. `PR Plan Review - Kickoff` seeds the `plan-review:*` labels and explains that the same five roles will compare the implementation against the approved issue plan, the diff, and the verification evidence.
17. The five PR reviewers discuss the pull request in thread, reply to each other when concerns intersect, and revisit approvals when new commits or corrections materially change the implementation.
18. `PR Plan Review - Reconcile State` normalises the pending PR labels and applies `plan-review:ready-to-merge` once all five PR review approvals are present.

The live issue ready-state reconciliation is handled by `Issue Planning - Reconcile State` because bot-applied labels do not reliably trigger another agentic workflow run. Bot-to-bot planning follow-ups are handled by `Issue Planning - Bot Follow Up`, while the issue role workflows themselves keep `github-actions` in `skip-bots` to avoid self-loops.

PR follow-ups are handled by `PR Plan Review - Bot Follow Up`, and `PR Plan Review - Reconcile State` owns the live `plan-review:ready-to-merge` transition. If a workflow cannot see the live issue or PR context clearly enough to verify the state, it should keep the thread open rather than guessing.

### Portable rollout pattern for other repositories

Use this rollout order when you add the planning team elsewhere:

1. Prove the Copilot-backed path first with a minimal verifier workflow. Do not assume secret validation alone proves inference works.
2. Install or customise `issue-triage` so every real issue enters a lightweight intake state, then add `issue-product-validation-dispatch`, `issue-product-validation`, `issue-planning-command`, the issue-planning kickoff, bot-follow-up dispatcher, five role workflows, ready-check, and reconcile workflow, plus the matching PR plan-review kickoff, bot-follow-up dispatcher, five role workflows, ready-check, and reconcile workflow.
3. Create the intake, planning, and `plan-review:*` labels before live testing so all three stages have stable targets.
4. Seed all five `planning/<role>` memory branches up front by creating the files `principles.md`, `repository-context.md`, and `history/recent-decisions.md`, plus the `issues/` and `pull-requests/` directories, rather than waiting for first use.
5. Before expecting repo-memory writes to work, verify that `planning/*` can accept workflow-created commits. On repositories with required signed commits, either provide an approved `planning/*` exemption or configure workflow commit signing before live rollout.
6. Retest on at least one realistic issue and one workflow-health issue. Use the realistic issue as the main proof. For workflow-health issues, ask a concrete portability or design question; otherwise reviewers may collapse into one-shot approvals instead of a real discussion.
7. Prove the intake gate as well as the planning gate: a new issue should be triaged, Product should either validate or challenge its fit, and `/doit` from an authorised maintainer should be the only path that starts the full five-role planning discussion.
8. After an issue reaches `planning:ready-for-dev`, open a small same-repo pull request that includes `Plan issue: #<issue-number>` in the body and prove that the PR review lane reaches `plan-review:ready-to-merge` with real back-and-forth between roles.
9. Keep `Issue Planning - Ready Check` and `PR Plan Review - Ready Check` as manual audit paths, and let the reconcile workflows own the live label normalisation.
10. On strict repositories, do not declare the rollout complete until both the issue-planning and PR plan-review workflows can persist their role memory using an approved write path.

### Resetting or retesting planning and plan review

On the default branch, new issues enter `issue-triage` automatically, Product validation reacts to that intake state, `/doit` from an authorised repository writer starts the planning lane, `Issue Planning - Reconcile State` keeps the planning labels aligned after each role workflow completes, and `PR Plan Review - Reconcile State` does the same for pull requests.

Before merge, or when manually re-running either stage, use `workflow_dispatch` with an issue number or pull request number. For example:

```bash
gh workflow run issue-triage.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-product-validation-dispatch.yml --ref <branch> -f issue_number=123
gh workflow run issue-product-validation.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-kickoff.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-product.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-security.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-performance.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-quality.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-architecture.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-reconcile.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-ready-check.lock.yml --ref <branch> -f issue_number=123

gh workflow run pr-plan-review-kickoff.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-product.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-security.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-performance.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-quality.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-architecture.lock.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-reconcile.yml --ref <branch> -f pr_number=123
gh workflow run pr-plan-review-ready-check.lock.yml --ref <branch> -f pr_number=123
```

Use `Issue Planning - Reconcile State` for the live issue label repair path and `Issue Planning - Ready Check` as a manual issue audit.

Use `PR Plan Review - Reconcile State` for the live PR label repair path and `PR Plan Review - Ready Check` as a manual PR audit.

For workflows that only exist on a feature branch, `gh workflow run --ref <branch>` can be unreliable. Prefer a push-trigger smoke test before merge, then re-run the intake, issue-planning, and PR plan-review workflows again on the default branch once they land.

To restart intake for an existing issue, re-run `issue-triage` or `Issue Product Validation`. To restart full planning for an intake-approved issue, use `/doit` again or manually dispatch `Issue Planning - Kickoff`. To restart PR plan review for an existing pull request, re-run `PR Plan Review - Kickoff` or push a new commit after clarifying the linked plan.
