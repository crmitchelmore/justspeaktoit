---
name: PR Plan Review - Ready Check
description: Manually audit ready-to-merge state for a specific pull request
on:
  workflow_dispatch:
    inputs:
      pr_number:
        description: "Pull request number to audit"
        required: true
        type: string

permissions:
  contents: read
  issues: read
  pull-requests: read

network:
  allowed:
    - defaults
    - github

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
    max: 2
    allowed:
      - plan-review:in-discussion
      - plan-review:ready-to-merge
  remove-labels:
    target: "*"
    max: 2
    allowed:
      - plan-review:in-discussion
      - plan-review:ready-to-merge

timeout-minutes: 10
engine:
  id: copilot
  version: "1.0.20"
  env:
    COPILOT_EXP_COPILOT_CLI_MCP_ALLOWLIST: "false"
---
# PR Plan Review Ready Check

Manually audit the plan-review state for pull request #${{ github.event.inputs.pr_number }}.

## Approval labels

All of these must be present for the pull request to be ready:

- `plan-review:product-approved`
- `plan-review:security-approved`
- `plan-review:performance-approved`
- `plan-review:quality-approved`
- `plan-review:architecture-approved`
- `plan-review:design-approved`

## Instructions

1. Read the pull request's current labels and recent plan-review comments.
2. If all six approval labels are present:
   - add `plan-review:ready-to-merge` if it is missing,
   - remove `plan-review:in-discussion` if it is present,
   - leave one short comment starting with `### ✅ Plan Review Ready` only if you changed the ready state. The comment should also state that the PR is now aligned with the approved plan and ready for final human merge checks.
3. If any approval label is missing:
   - remove `plan-review:ready-to-merge` if it is present,
   - add `plan-review:in-discussion` if it is missing,
   - leave one short comment starting with `### ♻️ Plan Review Reopened` only if you changed the ready state.
4. If the labels already match the approval state, do nothing.
5. Never change role-specific approval or pending labels in this manual audit workflow.
