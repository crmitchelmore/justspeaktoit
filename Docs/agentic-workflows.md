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

- `issue-triage` — triages new issues and adds a concise analysis comment
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

Each role memory should keep four compact files on its `planning/<role>` branch:

- `principles.md` — stable heuristics for that role
- `repository-context.md` — verified repo facts that repeatedly matter during planning
- `issues/<issue-number>.md` — the live stance and resolved blockers for a specific issue
- `history/recent-decisions.md` — durable decisions and learnings

### Workflows

Custom planning workflows added in this repository:

- `issue-planning-kickoff` — seeds the planning labels and explains the flow
- `issue-planning-bot-follow-up` — deterministic dispatcher that re-queues the other reviewers when a bot-authored planning comment lands
- `issue-planning-product`
- `issue-planning-security`
- `issue-planning-performance`
- `issue-planning-quality`
- `issue-planning-architecture`
- `issue-planning-ready-check` — manual agentic audit for a specific issue
- `issue-planning-reconcile` — deterministic label reconciler that runs after role workflows finish

### Labels

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

### Normal operating flow

1. A new issue opens.
2. `Issue Planning - Kickoff` adds the planning labels and posts a short explanation.
3. `Issue Planning - Bot Follow Up` sees the kickoff comment on the default branch and dispatches the five role reviewers.
4. Each role reviewer comments in thread, asks focused follow-up questions, and bot-authored reviewer comments re-dispatch the other reviewers without letting a workflow react to its own comment directly.
5. Maintainers answer unresolved questions in-thread, and those direct maintainer comments trigger the role reviewers as well.
6. If a maintainer explicitly asks a named role to respond, that role should leave a visible follow-up comment even if its approval label stays unchanged.
7. Role approval labels accumulate as concerns are resolved.
8. `Issue Planning - Reconcile State` normalises the pending labels and applies `planning:ready-for-dev` once all five approvals are present.

The live ready-state reconciliation is handled by `Issue Planning - Reconcile State` because bot-applied labels do not reliably trigger another agentic workflow run. Bot-to-bot planning follow-ups are handled by `Issue Planning - Bot Follow Up`, while the role workflows themselves keep `github-actions` in `skip-bots` to avoid self-loops.


### Portable rollout pattern for other repositories

Use this rollout order when you add the planning team elsewhere:

1. Prove the Copilot-backed path first with a minimal verifier workflow. Do not assume secret validation alone proves inference works.
2. Install the kickoff workflow, the deterministic bot-follow-up dispatcher, the five role workflows, the manual ready-check, and the deterministic reconcile workflow.
3. Create the planning labels before live testing so approvals have a stable target.
4. Seed all five `planning/<role>` memory branches up front by creating the files `principles.md`, `repository-context.md`, and `history/recent-decisions.md`, plus the `issues/` directory, rather than waiting for first use.
5. Retest on at least one realistic issue and one workflow-health issue, and confirm that reviewers reference each other's comments, visibly answer direct maintainer asks, and do more than leave one-shot approvals.
6. Keep `Issue Planning - Ready Check` as a manual audit path and let `Issue Planning - Reconcile State` own the live label normalisation.

### Resetting or retesting planning

On the default branch, the issue open/comment events run automatically, and `Issue Planning - Reconcile State` keeps the planning labels aligned after each role workflow completes.

Before merge, or when manually re-running the flow, use `workflow_dispatch` with an issue number. For example:

```bash
gh workflow run issue-planning-kickoff.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-product.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-security.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-performance.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-quality.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-architecture.lock.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-reconcile.yml --ref <branch> -f issue_number=123
gh workflow run issue-planning-ready-check.lock.yml --ref <branch> -f issue_number=123
```

Use `Issue Planning - Reconcile State` for the live label repair path and `Issue Planning - Ready Check` as a manual audit if you need the agent to re-evaluate a specific issue.

For workflows that only exist on a feature branch, `gh workflow run --ref <branch>` can be unreliable. Prefer a push-trigger smoke test before merge, then re-run the planning workflows again on the default branch once they land.

To restart planning for an existing issue, either reopen it or manually dispatch `Issue Planning - Kickoff` again.
