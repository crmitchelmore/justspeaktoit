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
    max: 1
    labels: [automation, coordination]
    expires: 1d

timeout-minutes: 10
engine: copilot
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

If you find conflicts, stale work, or more than 6 open improvement items, create a single coordination issue with:

- Title: `[coordination] Improvement agent status — $(date +%Y-%m-%d)`
- A table of all open improvement PRs and issues
- Specific recommendations (close stale PR X, PR Y and Z overlap on file F)
- Tag with `automation, coordination` labels

If everything looks healthy (no conflicts, ≤6 open items, no stale PRs), do nothing.

## Operating constraints

- Never modify PRs or issues directly. Only create a coordination report.
- Never close or merge anything.
- Keep the report actionable and concise.
