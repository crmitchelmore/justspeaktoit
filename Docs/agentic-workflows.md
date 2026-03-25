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

Recommended configuration:

- preferred: a fine-grained personal access token with the `Copilot Requests` permission enabled
- also supported by Copilot CLI: OAuth tokens from the GitHub CLI app / Copilot CLI app
- not supported: classic personal access tokens (`ghp_...`)

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
- **Casey Doyle** (`Code Quality`) — reviews maintainability, testing, and support burden
  - signature habits: names the failure mode before the fix, watches for surprise surface area, and prefers repair notes over drama
- **Morgan Reed** (`Architecture`) — reviews boundaries, sequencing, coupling, and rollout shape
  - signature habits: sketches boxes and arrows mentally, asks what breaks if a layer disappears, and keeps an allowed-seams map

Each role has:

- its own named Copilot custom agent file in `.github/agents/`
- its own workflow in `.github/workflows/`
- its own `repo-memory` branch under `planning/<role>`

The role memories capture each teammate's stable identity, recurring viewpoints, verified repository context, issue-specific decisions, and long-term heuristics so future reviews build on prior product and engineering thinking.

Each role memory should keep six compact files or areas on its `planning/<role>` branch:

- `persona.md` — the stable name, signature habits, and earned quirks for that role in this repository
- `principles.md` — stable heuristics for that role
- `repository-context.md` — verified repo facts that repeatedly matter during planning and implementation review
- `issues/<issue-number>.md` — the live stance and resolved blockers for a specific issue
- `pull-requests/<pr-number>.md` — the PR review stance, implementation drift, approved deviations, and merge notes for a specific pull request
- `history/recent-decisions.md` — durable decisions and learnings

On repositories with stricter branch protections, the planning setup is only operationally complete once workflow-driven memory updates can still land on `planning/<role>`. If the repository requires signed commits on all branches, either exempt `planning/*` or configure workflow commit signing up front.

### Workflows

Custom planning and plan-review workflows added in this repository:

- `issue-product-validation` — Alex Hale (`Product`) handles the first intake pass and decides whether the issue fits this repository before full planning is allowed to start
- `issue-planning-command` — accepts an authorised `/doit` command even when it appears inside a longer maintainer comment, seeds planning state, and posts the kickoff comment that starts full planning with any surrounding text carried over as context
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
2. `Issue Product Validation` acts as the first intake gate and reviews the issue from the Product lens.
3. Alex Hale (`Product`) either:
   - marks it `triage:product-fit`,
   - asks for more detail with `triage:needs-clarification`, or
   - marks it `triage:out-of-scope`.
4. Maintainers can answer Product's questions in-thread or edit the issue until Product validation converges.
5. Once `triage:product-fit` is present, someone with repository write access comments `/doit` on the issue. The command can stand alone or appear inside a longer maintainer note; any other text in that comment is carried into planning as context.
6. `Issue Planning - Command` verifies that the commenter has write access, clears the intake labels, applies the `planning:*` labels, and posts the `### 🗂️ Planning Kickoff` comment.
7. `Issue Planning - Kickoff` remains available as the manual reset and re-entry path when maintainers want to restart planning explicitly.
8. The five named teammates now join the thread:
   - Alex Hale (`Product`)
   - Priya Shah (`Security`)
   - Theo Quinn (`Performance`)
   - Casey Doyle (`Code Quality`)
   - Morgan Reed (`Architecture`)
9. Each reviewer comments in thread, asks focused follow-up questions, and bot-authored reviewer comments re-dispatch the other reviewers without letting a workflow react to its own comment directly.
10. Maintainers answer unresolved questions in-thread, and those direct maintainer comments trigger the issue reviewers as well.
11. If a maintainer explicitly asks a named role to respond, that role should leave a visible follow-up comment even if its approval label stays unchanged.
12. If a maintainer correction or verified repository fact disproves an earlier assumption, reviewers should revisit any approval that depended on it rather than leaning on older labels or comments as if the corrected concern were already resolved.
13. Role approval labels accumulate as concerns are resolved.
14. `Issue Planning - Reconcile State` normalises the pending labels and applies `planning:ready-for-dev` once all five approvals are present.
15. The implementer opens a pull request and includes `Plan issue: #<issue-number>` in the PR body, ideally alongside a closing reference such as `Closes #<issue-number>`.
16. `PR Plan Review - Kickoff` seeds the `plan-review:*` labels and explains that the same five named roles will compare the implementation against the approved issue plan, the diff, and the verification evidence.
17. The five PR reviewers discuss the pull request in thread, reply to each other when concerns intersect, and revisit approvals when new commits or corrections materially change the implementation.
18. `PR Plan Review - Reconcile State` normalises the pending PR labels and applies `plan-review:ready-to-merge` once all five PR review approvals are present.

The live issue ready-state reconciliation is handled by `Issue Planning - Reconcile State` because bot-applied labels do not reliably trigger another agentic workflow run. Bot-to-bot planning follow-ups are handled by `Issue Planning - Bot Follow Up`, while the issue role workflows themselves keep `github-actions` in `skip-bots` to avoid self-loops.

PR follow-ups are handled by `PR Plan Review - Bot Follow Up`, and `PR Plan Review - Reconcile State` owns the live `plan-review:ready-to-merge` transition. If a workflow cannot see the live issue or PR context clearly enough to verify the state, it should keep the thread open rather than guessing.

### How team personalities build memory

Each named reviewer has a stable identity and an evolving repository memory:

- `persona.md` keeps the stable name, signature habits, and only the quirks that have been earned through repeated repository history
- `principles.md` captures recurring judgement patterns
- `repository-context.md` stores verified facts that repeatedly matter to that role
- `history/recent-decisions.md` records the calls that changed future judgement
- issue and PR files capture the live stance, then graduate lasting lessons back into the durable files

The rule is simple: names stay stable, judgement improves, and quirks only deepen when the memory shows they are genuinely part of how that teammate now works.

### When to use `/doit`

`/doit` is the maintainer handoff from Product validation into full planning. Use it only when all of these are true:

- the issue already has `triage:product-fit`
- someone with repository write access is making the comment
- the issue is ready for Alex, Priya, Theo, Casey, and Morgan to start the full planning discussion rather than still needing Product clarification

Do not use `/doit` while the issue still lacks `triage:product-fit`, or while it is in `triage:needs-clarification` or `triage:out-of-scope`. In those states, continue the Product discussion in-thread or update the issue until Product validation changes.

`/doit` does not need to be the whole comment. A maintainer can write a short note such as scope guidance, a preferred option, or an answer to an open question in the same comment. The workflow will treat `/doit` as the command and carry the surrounding text into the kickoff comment as planning context.

Once `/doit` is accepted, the issue moves into `planning:*` labels, the kickoff comment starts the five-role discussion, and maintainers should answer open questions in-thread until `planning:ready-for-dev` appears. If the `/doit` comment included extra text, that text is quoted into the kickoff comment as maintainer planning context. The resulting pull request should then include `Plan issue: #<issue-number>` in the body so the PR review lane can compare the implementation against the approved plan.

### Portable rollout pattern for other repositories

Use this rollout order when you add the planning team elsewhere:

1. Prove the Copilot-backed path first with a minimal verifier workflow. Do not assume secret validation alone proves inference works.
2. Make Product validation the first gate for new issues, then add `issue-planning-command`, the issue-planning kickoff, bot-follow-up dispatcher, five role workflows, ready-check, and reconcile workflow, plus the matching PR plan-review kickoff, bot-follow-up dispatcher, five role workflows, ready-check, and reconcile workflow.
3. Name the team up front. Give each role a human name and 2-3 signature habits in `.github/agents/planning-<role>.agent.md`, and keep the role label explicit in comments.
4. Create the intake, planning, and `plan-review:*` labels before live testing so all three stages have stable targets.
5. Seed all five `planning/<role>` memory branches up front by creating `persona.md`, `principles.md`, `repository-context.md`, and `history/recent-decisions.md`, plus the `issues/` and `pull-requests/` directories, rather than waiting for first use.
6. Before expecting repo-memory writes to work, verify that `planning/*` can accept workflow-created commits. On repositories with required signed commits, either provide an approved `planning/*` exemption or configure workflow commit signing before live rollout.
7. Retest on at least one realistic issue and one workflow-health issue. Use the realistic issue as the main proof. For workflow-health issues, ask a concrete portability or design question; otherwise reviewers may collapse into one-shot approvals instead of a real discussion.
8. Prove the intake gate as well as the planning gate: a new issue should get a Product fit review directly on open, Product should either validate or challenge its fit, and `/doit` from an authorised maintainer should be the only path that starts the full five-role planning discussion.
9. After an issue reaches `planning:ready-for-dev`, open a small same-repo pull request that includes `Plan issue: #<issue-number>` in the body and prove that the PR review lane reaches `plan-review:ready-to-merge` with real back-and-forth between roles.
10. Keep `Issue Planning - Ready Check` and `PR Plan Review - Ready Check` as manual audit paths, and let the reconcile workflows own the live label normalisation.
11. On strict repositories, do not declare the rollout complete until both the issue-planning and PR plan-review workflows can persist their role memory using an approved write path.

### Resetting or retesting planning and plan review

On the default branch, new issues enter `Issue Product Validation` automatically, `/doit` from an authorised repository writer starts the planning lane, and any extra text in that comment is carried into the kickoff note as planning context. `Issue Planning - Reconcile State` keeps the planning labels aligned after each role workflow completes, and `PR Plan Review - Reconcile State` does the same for pull requests.

Before merge, or when manually re-running either stage, use `workflow_dispatch` with an issue number or pull request number. For example:

```bash
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

For workflows that only exist on a feature branch, `gh workflow run --ref <branch>` can be unreliable. Use this proof pattern instead:

1. On the feature branch, validate the source changes and generated lock files directly (for example with `gh aw compile`, `git diff`, and any existing CI or push-trigger smoke test).
2. Open a linked pull request from that branch so the PR review lane can run against the branch workflow definitions before merge.
3. After merge, open a fresh issue and a small linked pull request (for example, a documentation update) on the default branch to prove the paths that depend on default-branch workflow definitions: issue-open Product validation, `/doit` planning kickoff, and any manual `workflow_dispatch` reconcile or ready-check runs.

This repository used that exact pattern after PR `#175`: the branch proved the workflow sources and PR review lane, while issue `#176` on `main` proved the default-branch intake and reconcile behaviour.

To restart intake for an existing issue, re-run `Issue Product Validation`. To restart full planning for an intake-approved issue, use `/doit` again (optionally with a short maintainer note that will be carried into kickoff) or manually dispatch `Issue Planning - Kickoff`. To restart PR plan review for an existing pull request, re-run `PR Plan Review - Kickoff` or push a new commit after clarifying the linked plan.

#### Recovering from stale PR plan-review comments

If a pull request is opened before its approved planning issue is linked in the body, the first PR review pass may leave stale comments that only reflect the missing-plan state.

Use this recovery path:

1. Edit the PR body so it includes `Plan issue: #<issue-number>`, ideally alongside `Closes #<issue-number>` or an equivalent closing reference.
2. If the thread still reflects the old state, add one maintainer clarification comment that points reviewers at the approved issue and answers any open questions that were resolved outside the first pass.
3. Re-run `PR Plan Review - Kickoff` or the affected `pr-plan-review-<role>.lock.yml` workflows so the same five reviewers evaluate the updated PR state.
4. Let `PR Plan Review - Reconcile State` normalise the labels back to `plan-review:ready-to-merge` once all five approvals converge again.

This recovery path re-runs the normal plan-review gate; it does not bypass or weaken it. PR plan-review role workflows should only respond on pull-request threads, while issue-planning threads should stay limited to the five issue-planning reviewers.
