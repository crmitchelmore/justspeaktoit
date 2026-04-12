---
on:
  push:
    branches:
      - chore/setup-agentic-workflows-team
  workflow_dispatch:
    inputs:
      issue_number:
        description: Issue number to use for the basics verification comment
        required: false

permissions:
  contents: read
  issues: read
  pull-requests: read

engine:
  id: copilot
  version: "1.0.21"

tools:
  github:
    toolsets: [issues]

network: defaults

safe-outputs:
  report-failure-as-issue: false
  add-comment:

---

# Verify basics

Verify that GitHub Agentic Workflows can run successfully in this repository with the existing Copilot token setup.

## Task

1. If the `issue_number` workflow input is present, read that GitHub issue, confirm that you can access the issue details, and add exactly one short comment confirming that the basics check succeeded for `crmitchelmore/justspeaktoit`.
2. If no `issue_number` input is present, call `noop` with a short confirmation that the basics check succeeded on this branch.

## Guardrails

- Keep the comment short and practical.
- Do not modify labels, files, or issue metadata.
- Add only one comment if an issue number is provided.
- If the issue cannot be read, use the one allowed comment to explain the blocker clearly.
- If there is no issue number, do not try to add a comment.

## Usage

Run with `gh aw run verify-basics --push -F issue_number=<issue-number>`, or rely on the push trigger for a branch-level basics check.
