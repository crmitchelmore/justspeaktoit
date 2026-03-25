---
name: Issue Planning - Kickoff
description: Seed issue-planning labels and explain the review flow on new issues
on:
  issues:
    types: [opened, reopened]
  workflow_dispatch:
    inputs:
      issue_number:
        description: "Issue number to initialise"
        required: true
        type: string
  skip-bots: [github-actions, copilot, dependabot, renovate]

if: github.event_name == 'workflow_dispatch' || github.event.issue.pull_request == null

permissions:
  contents: read
  issues: read

network: defaults

tools:
  github:
    toolsets: [issues, labels]

safe-outputs:
  add-comment:
    max: 1
    target: "*"
    hide-older-comments: true
  add-labels:
    target: "*"
    max: 6
    allowed:
      - planning:in-discussion
      - planning:needs-product
      - planning:needs-security
      - planning:needs-performance
      - planning:needs-quality
      - planning:needs-architecture
  remove-labels:
    target: "*"
    max: 6
    allowed:
      - planning:ready-for-dev
      - planning:product-approved
      - planning:security-approved
      - planning:performance-approved
      - planning:quality-approved
      - planning:architecture-approved

timeout-minutes: 10
engine: copilot
---
# Issue Planning Kickoff

Initialise or reset the planning state for the selected issue.

## Instructions

1. Determine the issue number from the event context or `workflow_dispatch` input.
2. Never act on pull requests.
3. Ensure these labels are present on the issue:
   - `planning:in-discussion`
   - `planning:needs-product`
   - `planning:needs-security`
   - `planning:needs-performance`
   - `planning:needs-quality`
   - `planning:needs-architecture`
4. Remove these labels if present so the issue cleanly re-enters planning:
   - `planning:ready-for-dev`
   - `planning:product-approved`
   - `planning:security-approved`
   - `planning:performance-approved`
   - `planning:quality-approved`
   - `planning:architecture-approved`
5. Leave one short comment starting with `### 🗂️ Planning Kickoff` that:
   - explains that Product, Security, Performance, Code Quality, and Architecture reviewers will comment in-thread and may reply to each other while the plan is still moving,
   - tells maintainers to answer unresolved questions in-thread until the team converges,
   - tells maintainers the issue is ready when `planning:ready-for-dev` appears,
   - stays concise and operational.
6. If an equivalent kickoff comment already exists and the labels are already correct, do nothing.
