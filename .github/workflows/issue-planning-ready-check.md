---
name: Issue Planning - Ready Check
description: Manually audit ready-for-development state for a specific issue
on:
  workflow_dispatch:
    inputs:
      issue_number:
        description: "Issue number to audit"
        required: true
        type: string

permissions:
  contents: read
  issues: read

network: defaults

tools:
  github:
    toolsets: [issues, labels]

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
      - planning:in-discussion
      - planning:ready-for-dev
  remove-labels:
    target: "*"
    max: 2
    allowed:
      - planning:in-discussion
      - planning:ready-for-dev

timeout-minutes: 10
engine:
  id: copilot
  version: "1.0.21"
  env:
    COPILOT_EXP_COPILOT_CLI_MCP_ALLOWLIST: "false"
---
# Issue Planning Ready Check

Manually audit the planning state for issue #${{ github.event.inputs.issue_number }}.

## Approval state

All of these must be true for the issue to be ready:

- `planning:product-approved`
- `planning:security-approved`
- `planning:performance-approved`
- `planning:quality-approved`
- `planning:architecture-approved`
- `planning:reliability-approved`
- `planning:design-approved`
- the latest `### 👔 Engineering Manager` comment must contain `Decision: approved`
- that EM approval must be at least as recent as the latest specialist planning comment

## Instructions

1. Read the issue's current labels and recent planning comments.
2. If all seven approval labels are present and the latest Engineering Manager decision is `approved` on the current specialist discussion:
    - add `planning:ready-for-dev` if it is missing,
    - remove `planning:in-discussion` if it is present,
    - leave one short comment starting with `### ✅ Planning Ready` only if you changed the ready state. The comment should also tell the implementer to open a pull request that includes `Plan issue: #<issue-number>` in the body so the PR review lane can compare implementation to the approved plan.
3. If any approval label is missing, or the latest Engineering Manager decision is missing/stale/challenging:
    - remove `planning:ready-for-dev` if it is present,
    - add `planning:in-discussion` if it is missing,
    - leave one short comment starting with `### ♻️ Planning Reopened` only if you changed the ready state.
4. If the labels already match the approval state, do nothing.
5. Never change role-specific approval or pending labels in this manual audit workflow.
