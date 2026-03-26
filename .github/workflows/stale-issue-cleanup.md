---
name: Stale Issue Cleanup
description: Close stale automation failure issues that are no longer actionable
on:
  schedule: weekly
  workflow_dispatch:
permissions:
  contents: read
  issues: read
  pull-requests: read

network: defaults

tools:
  bash: true
  github:
    toolsets: [default, issues]

safe-outputs:
  report-failure-as-issue: false
  add-comment:
    max: 20
    target: "*"
  close-issue:
    max: 20

timeout-minutes: 10
engine: copilot
---
# Stale Issue Cleanup

You clean up stale automation-generated issues in `${{ github.repository }}` that are no longer actionable.

## Target issues

Find open issues that match ALL of these criteria:

1. Have the `agentic-workflows` label.
2. Title starts with `[aw]` (indicating an automated failure report).
3. Were created more than 7 days ago.
4. Have no human comments (comments from `github-actions[bot]` or `copilot[bot]` do not count as human).

Use the GitHub CLI to find candidates:

```bash
gh issue list --repo ${{ github.repository }} --state open --label agentic-workflows --json number,title,createdAt,comments,author --limit 50
```

## Decision logic

For each candidate issue:

### Close if:
- The issue is older than 7 days AND has no human comments.
- The workflow that failed has had at least one successful run since the failure (check with `gh run list`).

### Keep if:
- A human has commented on the issue (someone is investigating).
- The workflow is still consistently failing (no successful runs since the failure).
- The issue contains a root cause analysis that might still be relevant.

## How to close

For each issue you close, add a comment before closing:

```
### 🧹 Auto-cleanup

This automated failure report is being closed because:
- The issue is over 7 days old with no human follow-up.
- [The underlying workflow has had successful runs since. / The failure appears to have been transient.]

If this issue is still relevant, reopen it and add a comment explaining what needs attention.
```

Then close the issue.

## Operating constraints

- Never close issues that don't have the `agentic-workflows` label.
- Never close issues where a human has engaged.
- Close a maximum of 20 issues per run.
- Be conservative: when in doubt, keep the issue open.
