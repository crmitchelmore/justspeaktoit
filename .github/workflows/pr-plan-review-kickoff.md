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
  report-failure-as-issue: false
  add-comment:
    max: 1
    target: "*"
    hide-older-comments: true
  add-labels:
    target: "*"
    max: 7
    allowed:
      - plan-review:in-discussion
      - plan-review:needs-product
      - plan-review:needs-security
      - plan-review:needs-performance
      - plan-review:needs-quality
      - plan-review:needs-architecture
      - plan-review:needs-design
  remove-labels:
    target: "*"
    max: 14
    allowed:
      - plan-review:in-discussion
      - plan-review:needs-product
      - plan-review:needs-security
      - plan-review:needs-performance
      - plan-review:needs-quality
      - plan-review:needs-architecture
      - plan-review:needs-design
      - plan-review:ready-to-merge
      - plan-review:product-approved
      - plan-review:security-approved
      - plan-review:performance-approved
      - plan-review:quality-approved
      - plan-review:architecture-approved
      - plan-review:design-approved

timeout-minutes: 10
engine:
  id: copilot
  version: "1.0.21"
  env:
    COPILOT_EXP_COPILOT_CLI_MCP_ALLOWLIST: "false"
---
# PR Plan Review Kickoff

Initialise or reset the plan-review state for the selected pull request.

## Instructions

1. Determine the pull request number from the event context or `workflow_dispatch` input.
2. If the pull request is a draft, do nothing.
3. If this run came from the automatic `pull_request` trigger and the pull request head branch starts with `renovate/`, do nothing. Routine Renovate PRs should stay on the normal verification lanes and the Renovate fix-agent flow by default. Maintainers can still opt into the full specialist PR plan-review lane later with an explicit manual dispatch if they need it.
4. Inspect the changed files on the pull request. If every changed file stays within the agentic-workflow maintenance surface (`.github/workflows/**`, `.github/aw/**`, `.github/agents/**`, `.github/copilot-instructions.md`, `Docs/agentic-workflows.md`, `.vscode/settings.json`, `.vscode/mcp.json`, `.gitattributes`):
   - remove any existing `plan-review:*` labels from the pull request so it stays out of the specialist review lane,
   - leave one short comment starting with `### ⏭️ Plan Review Skipped` that says this PR only changes agentic workflow/runtime infrastructure, does not need an issue-plan seam, and should rely on the normal verification lanes unless maintainers explicitly ask for extra review in-thread,
   - do not post the blocked or kickoff comment,
   - do not add the `plan-review:needs-*` labels.
5. Otherwise find the linked planning issue. Prefer an explicit `Plan issue: #<issue-number>` line in the PR body. If that is absent, fall back to one clear closing or reference keyword such as `Closes #<n>`, `Fixes #<n>`, `Resolves #<n>`, or `Refs #<n>`.
6. If there is not exactly one clear linked issue, or the linked issue is not currently `planning:ready-for-dev`:
   - remove any existing `plan-review:*` labels from the pull request so the PR stays out of the active review lane,
   - leave one short comment starting with `### 🛂 Plan Review Blocked` that states the exact blocker, tells maintainers to link one approved planning issue with `Plan issue: #<issue-number>`, and says the specialist PR reviewers will wait until that approved plan seam exists,
   - do not post the normal kickoff comment,
   - do not add the `plan-review:needs-*` labels.
7. Otherwise ensure these labels are present on the pull request:
   - `plan-review:in-discussion`
   - `plan-review:needs-product`
   - `plan-review:needs-security`
   - `plan-review:needs-performance`
   - `plan-review:needs-quality`
   - `plan-review:needs-architecture`
   - `plan-review:needs-design`
8. Remove these labels if present so the pull request cleanly re-enters plan review:
   - `plan-review:ready-to-merge`
   - `plan-review:product-approved`
   - `plan-review:security-approved`
   - `plan-review:performance-approved`
   - `plan-review:quality-approved`
   - `plan-review:architecture-approved`
   - `plan-review:design-approved`
9. Leave one short comment starting with `### 🔎 Plan Review Kickoff` that:
   - explains that Product, Security, Performance, Code Quality, Architecture, and Design reviewers will compare the PR against the approved issue plan and may reply to each other while implementation review is still moving,
   - tells maintainers to include `Plan issue: #<issue-number>` in the PR body, ideally alongside a closing reference such as `Closes #<issue-number>`,
   - tells maintainers to answer unresolved questions in-thread until the team converges on `plan-review:ready-to-merge`,
   - stays concise and operational.
10. If an equivalent skipped, blocked, or kickoff comment already exists and the labels already match the current state, do nothing.
