---
description: |
  This workflow maintains a rolling repository status report. It gathers recent
  repository activity (issues, PRs, discussions, releases, code changes) and
  updates one concise status issue only when there is meaningful maintainer-facing
  information to share.

on:
  schedule: daily
  workflow_dispatch:

permissions:
  contents: read
  issues: read
  pull-requests: read

network: defaults

tools:
  github:
    # If in a public repo, setting `lockdown: false` allows
    # reading issues, pull requests and comments from 3rd-parties
    # If in a private repo this has no particular effect.
    lockdown: false
    min-integrity: none # This workflow is allowed to examine and comment on any issues

safe-outputs:
  report-failure-as-issue: false
  mentions: false
  allowed-github-references: []
  create-issue:
    title-prefix: "[repo-status] "
    labels: [report, daily-status]
    max: 1
  update-issue:
    target: "*"
    title-prefix: "[repo-status] "
    max: 1
  noop:
    report-as-issue: false
source: githubnext/agentics/workflows/daily-repo-status.md@97143ac59cb3a13ef2a77581f929f06719c7402a
engine:
  id: copilot
  version: "1.0.21"
---

# Daily Repo Status

Maintain a single rolling repo status issue for the repo. Do not open a fresh daily issue.

## What to include

- Only meaningful recent repository activity (issues, PRs, releases, code changes)
- A short summary of progress or blockers that materially changed since the last update
- At most 3 actionable next steps for maintainers

## Style

- Be positive, encouraging, and helpful 🌟
- Use emojis moderately for engagement
- Keep it concise - skip repeated unchanged metrics and stale narrative

## Process

1. Gather recent activity from the repository
2. Study the repository, its issues and its pull requests
3. Search for an open issue titled `[repo-status] Rolling Repo Status`
4. If it exists and there is meaningful change, update it in place
5. If it does not exist and there is meaningful maintainer-facing information, create it
6. If there is no meaningful change and no maintainer action needed, do nothing

## Output shape

- Use the title `[repo-status] Rolling Repo Status`
- Start with `Last updated: YYYY-MM-DD`
- Keep the body to short sections for `Highlights`, `Needs attention`, and `Next actions`
- Remove stale or completed items when updating the rolling issue instead of appending a changelog
