---
name: PR Plan Review - Kickoff
description: Seed PR plan-review labels and explain the implementation review flow
on:
  pull_request:
    types: [opened, reopened, ready_for_review]
  workflow_dispatch:
    inputs:
      pr_number:
        description: "Pull request number to initialise"
        required: true
        type: string
  skip-bots: [github-actions, copilot, dependabot, renovate]

permissions:
  contents: read
  issues: read
  pull-requests: read

network: defaults

tools:
  github:
    toolsets: [default, labels]

safe-outputs:
  add-comment:
    max: 1
    target: "*"
    hide-older-comments: true
  add-labels:
    target: "*"
    max: 6
    allowed:
      - plan-review:in-discussion
      - plan-review:needs-product
      - plan-review:needs-security
      - plan-review:needs-performance
      - plan-review:needs-quality
      - plan-review:needs-architecture
  remove-labels:
    target: "*"
    max: 6
    allowed:
      - plan-review:ready-to-merge
      - plan-review:product-approved
      - plan-review:security-approved
      - plan-review:performance-approved
      - plan-review:quality-approved
      - plan-review:architecture-approved

timeout-minutes: 10
engine: copilot
---
# PR Plan Review Kickoff

Initialise or reset the plan-review state for the selected pull request.

## Instructions

1. Determine the pull request number from the event context or `workflow_dispatch` input.
2. If the pull request is a draft, do nothing.
3. Ensure these labels are present on the pull request:
   - `plan-review:in-discussion`
   - `plan-review:needs-product`
   - `plan-review:needs-security`
   - `plan-review:needs-performance`
   - `plan-review:needs-quality`
   - `plan-review:needs-architecture`
4. Remove these labels if present so the pull request cleanly re-enters plan review:
   - `plan-review:ready-to-merge`
   - `plan-review:product-approved`
   - `plan-review:security-approved`
   - `plan-review:performance-approved`
   - `plan-review:quality-approved`
   - `plan-review:architecture-approved`
5. Leave one short comment starting with `### 🔎 Plan Review Kickoff` that:
   - explains that Product, Security, Performance, Code Quality, and Architecture reviewers will compare the PR against the approved issue plan and may reply to each other while implementation review is still moving,
   - tells maintainers to include `Plan issue: #<issue-number>` in the PR body, ideally alongside a closing reference such as `Closes #<issue-number>`,
   - tells maintainers to answer unresolved questions in-thread until the team converges on `plan-review:ready-to-merge`,
   - stays concise and operational.
6. If an equivalent kickoff comment already exists and the labels are already correct, do nothing.
