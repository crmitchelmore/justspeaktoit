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

The role memories capture recurring viewpoints, issue-specific decisions, and long-term heuristics so future reviews build on prior product and engineering thinking.

### Workflows

Custom planning workflows added in this repository:

- `issue-planning-kickoff` — seeds the planning labels and explains the flow
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
3. Each role reviewer comments in thread, either asking for clarification or approving.
4. Role approval labels accumulate as concerns are resolved.
5. `Issue Planning - Reconcile State` normalises the pending labels and applies `planning:ready-for-dev` once all five approvals are present.

The live ready-state reconciliation is handled by `Issue Planning - Reconcile State` because bot-applied labels do not reliably trigger another agentic workflow run.

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

To restart planning for an existing issue, either reopen it or manually dispatch `Issue Planning - Kickoff` again.
