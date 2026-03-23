---
name: Issue Planning - Ready Check
description: Maintain the ready-for-development label once planning approvals change
on:
  issues:
    types: [opened, reopened, labeled, unlabeled]
  workflow_dispatch:
    inputs:
      issue_number:
        description: "Issue number to reconcile"
        required: true
        type: string

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
engine: copilot
---
# Issue Planning Ready Check

Reconcile the issue planning state from labels alone.

## Approval labels

All of these must be present for the issue to be ready:

- `planning:product-approved`
- `planning:security-approved`
- `planning:performance-approved`
- `planning:quality-approved`
- `planning:architecture-approved`

## Instructions

1. Determine the issue number from the event context or `workflow_dispatch` input.
2. Never act on pull requests.
3. Read the issue's current labels.
4. If all five approval labels are present and `planning:ready-for-dev` is missing:
   - add `planning:ready-for-dev`,
   - remove `planning:in-discussion`,
   - leave one short comment starting with `### ✅ Planning Ready`.
5. If any approval label is missing and `planning:ready-for-dev` is present:
   - remove `planning:ready-for-dev`,
   - add `planning:in-discussion`,
   - leave one short comment starting with `### ♻️ Planning Reopened`.
6. If the labels already reflect the correct state, do nothing.
7. Never touch role-specific approval or pending labels in this workflow.
