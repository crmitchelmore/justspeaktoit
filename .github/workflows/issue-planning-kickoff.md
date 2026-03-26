---
name: Issue Planning - Kickoff
description: Seed the planning labels and explain the issue-planning flow after an explicit /doit request
on:
  workflow_dispatch:
    inputs:
      issue_number:
        description: "Issue number to initialise"
        required: true
        type: string
  skip-bots: [github-actions, copilot, dependabot, renovate]

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
    max: 8
    allowed:
      - planning:in-discussion
      - planning:needs-product
      - planning:needs-security
      - planning:needs-performance
      - planning:needs-quality
      - planning:needs-architecture
      - planning:needs-reliability
      - planning:needs-design
  remove-labels:
    target: "*"
    max: 13
    allowed:
      - triage:pending-product-validation
      - triage:product-fit
      - triage:needs-clarification
      - triage:out-of-scope
      - planning:ready-for-dev
      - planning:product-approved
      - planning:security-approved
      - planning:performance-approved
      - planning:quality-approved
      - planning:architecture-approved
      - planning:reliability-approved
      - planning:design-approved

timeout-minutes: 10
engine: copilot
---
# Issue Planning Kickoff

Initialise or reset the planning state for the selected issue after an explicit `/doit` request or a manual dispatch.

## Instructions

1. Determine the issue number from the `workflow_dispatch` input for issue #${{ github.event.inputs.issue_number }}.
2. Never act on pull requests.
3. Ensure these labels are present on the issue:
   - `planning:in-discussion`
   - `planning:needs-product`
   - `planning:needs-security`
   - `planning:needs-performance`
   - `planning:needs-quality`
   - `planning:needs-architecture`
   - `planning:needs-reliability`
   - `planning:needs-design`
4. Remove these labels if present so the issue cleanly enters or re-enters planning:
   - `triage:pending-product-validation`
   - `triage:product-fit`
   - `triage:needs-clarification`
   - `triage:out-of-scope`
   - `planning:ready-for-dev`
   - `planning:product-approved`
   - `planning:security-approved`
   - `planning:performance-approved`
   - `planning:quality-approved`
   - `planning:architecture-approved`
   - `planning:reliability-approved`
   - `planning:design-approved`
5. Leave one short comment starting with `### 🗂️ Planning Kickoff` that:
   - explains that Product, Security, Performance, Code Quality, Architecture, Reliability, and Design reviewers will comment in-thread and may reply to each other while the plan is still moving,
   - says this kickoff happened because a repository writer explicitly requested planning,
   - tells maintainers to answer unresolved questions in-thread until the team converges,
   - tells maintainers the issue is ready when `planning:ready-for-dev` appears and the next step is to open a pull request that includes `Plan issue: #<issue-number>` in the body,
   - stays concise and operational.
6. Always leave a fresh kickoff comment when this workflow runs. If the labels were already correct, treat the new comment as the manual re-queue signal for the planning reviewers rather than doing nothing.
