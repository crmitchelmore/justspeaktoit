---
name: Improvement Coordinator
description: Check for open improvement PRs before daily agents run to prevent duplicates
on:
  schedule: daily
  workflow_dispatch:
permissions:
  contents: read
  issues: read
  pull-requests: read

network: defaults

tools:
  bash: true
  github:
    toolsets: [default, pull_requests, issues]
  cache-memory:
    - id: improvement-state
      key: improvement-coordinator-${{ github.workflow }}

safe-outputs:
  report-failure-as-issue: false
  create-issue:
    title-prefix: "[coordination] "
    max: 1
    labels: [automation, coordination]
    expires: 1d
  update-issue:
    target: "*"
    title-prefix: "[coordination] "
    max: 1
  noop:
    report-as-issue: false

timeout-minutes: 10
engine:
  id: copilot
  version: "1.0.21"
---
# Improvement Coordinator

You coordinate the daily improvement agents in `${{ github.repository }}` to prevent duplicate work and conflicting PRs.

## Improvement agents

The repository runs these autonomous improvement agents on a schedule:

| Agent | PR prefix | Labels |
|-------|-----------|--------|
| Daily Test Improver | `[Test Improver]` | `testing, automation` |
| Daily Perf Improver | `[Perf Improver]` | `performance, automation` |
| Daily Doc Updater | `[docs]` | `documentation, automation` |
| Repository Quality Improver | `[quality]` | `quality, automated-analysis` |
| Agentic Improvement | `[agentic]` | `automation` |

## What to do

### 1. Inventory open improvement work

Search for open PRs and issues created by these agents:

```bash
gh pr list --repo ${{ github.repository }} --state open --label automation --json number,title,labels,createdAt,author
gh issue list --repo ${{ github.repository }} --state open --label automation --json number,title,labels,createdAt
```

### 2. Detect conflicts

Check for:

- **Duplicate scope**: two PRs touching the same files or the same feature area.
- **Stale PRs**: improvement PRs open for more than 5 days without review activity.
- **Failed PRs**: improvement PRs where CI checks have failed.
- **Overlapping issues**: quality improvement issues covering the same area within the last 7 days.

### 3. Record state

Save the current inventory to cache memory at `/tmp/gh-aw/cache-memory/improvement-state/`:

```json
{
  "date": "YYYY-MM-DD",
  "open_prs": [{"number": 1, "title": "...", "agent": "test-improver", "days_open": 3}],
  "open_issues": [{"number": 2, "title": "...", "agent": "quality-improver"}],
  "conflicts": [],
  "stale": [],
  "recommendations": []
}
```

### 4. Report (if needed)

If you find conflicts, stale work, more than 2 open improvement PRs, or more than 4 open improvement items total, maintain a single coordination issue with:

- Title: `[coordination] Improvement agent status`
- Counts for open improvement PRs and issues
- Only the concrete overlaps, stale items, or blocked items that need maintainer action
- At most 5 specific recommendations (close stale PR X, PR Y and Z overlap on file F, pause new PR creation until backlog drops)
- Tag with `automation, coordination` labels

If an open coordination issue already exists, update it in place instead of creating a fresh dated issue.

If everything looks healthy (no conflicts, ≤2 open improvement PRs, ≤4 open items total, no stale PRs), do nothing.

## Operating constraints

- Never modify PRs or issues directly beyond creating or updating the single coordination report.
- Never close or merge anything.
- Never create purely informational daily status issues.
- Keep the report actionable and concise.
