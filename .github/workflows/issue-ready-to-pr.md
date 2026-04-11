---
name: Issue Ready to PR
description: Implement an approved issue plan and open a pull request automatically
on:
  issues:
    types: [labeled]
  workflow_dispatch:
    inputs:
      issue_number:
        description: "Issue number to implement"
        required: true
        type: string

if: github.event_name == 'workflow_dispatch' || (github.event.issue.pull_request == null && github.event.label.name == 'planning:ready-for-dev')

permissions:
  contents: read
  issues: read
  pull-requests: read

checkout:
  fetch: ["*"]
  fetch-depth: 0

network:
  allowed:
    - defaults
    - github
    - dotnet
    - node
    - python
    - rust
    - java

tools:
  github:
    toolsets: [default, search, issues, pull_requests]
  bash: true
  edit:

safe-outputs:
  report-failure-as-issue: false
  add-comment:
    max: 1
    target: "*"
    hide-older-comments: true
  create-pull-request:
    draft: false
    title-prefix: "[Plan] "
    labels: [automation, agentic-workflows]
    max: 2
    protected-files: fallback-to-issue

timeout-minutes: 45
engine:
  id: copilot
  version: "1.0.20"
  env:
    COPILOT_EXP_COPILOT_CLI_MCP_ALLOWLIST: "false"
---
# Issue Ready to PR

Implement an already-approved issue plan and open a pull request automatically.

## Trigger context

- If this run came from `workflow_dispatch`, implement issue #${{ github.event.inputs.issue_number }}.
- Otherwise implement the triggering issue #${{ github.event.issue.number }} because `planning:ready-for-dev` was applied.
- Never act on pull requests.
- If the issue does not currently have `planning:ready-for-dev`, do nothing.
- If open pull requests already exist whose body contains `Plan issue: #<issue-number>` and they collectively cover the entire approved plan scope, do nothing. If they only cover part of the plan (split implementation), proceed with uncovered scope.
- If the issue already has a recent bot comment starting with `### 🤖 Implementation Blocked` and nothing material changed since then, do nothing.

## Mission

Turn the approved issue plan into a real pull request with code, tests, and a clear PR body that links back to the issue plan.

## Workflow

1. Read the issue, the full planning discussion, and the current labels in full.
2. Treat the planning comments as the approved specification:
   - maintainer context from `/doit`, if present,
   - Product scope guardrails,
   - Security, Performance, Code Quality, Architecture, and Reliability constraints,
   - any explicit implementation direction the maintainers gave in-thread, including automatic maintainer-authored issue handoffs that skipped `/doit`,
   - the latest `### 👔 Engineering Manager` comment with `Decision: approved`, because that is the final cross-role coherence sign-off.
3. Search for existing open pull requests that already reference `Plan issue: #<issue-number>`. If one or more already exist, check what scope they cover. Only implement scope that is not already covered by an existing PR.
4. Read `AGENTS.md` and any relevant repository docs before changing code.
5. Determine if the approved plan calls for a split approach (e.g. Product or Architecture recommended shipping in separate PRs). Look for phrases like "ship independently", "separate PR", "split", or explicit sequencing guidance.
6. Create a fresh implementation branch from the default branch named `plan-issue/<issue-number>-<short-slug>` (append a suffix like `-part1`, `-part2` when splitting).
7. Implement the smallest correct change that satisfies the approved plan (or the current part if splitting). Do not widen scope just because you can.
8. Run the most relevant validation commands for the affected area. Prefer the same commands the repository already uses in CI or documentation.
9. If you made a valid change and the validation is good enough for review, create a pull request via the safe-output create-pull-request tool.
10. **If the plan requires a split**, create one PR per independently shippable piece (up to 2 PRs). Each PR should clearly state which part of the plan it implements and reference the other PR(s) in its body. Use `Closes #<issue-number>` only on the final PR that completes the full plan; earlier PRs should use `Part of #<issue-number>` instead.
11. If you cannot safely implement the issue, or the repository state prevents a responsible PR, leave one concise issue comment and do not create a PR.

## Pull request requirements

If you create a PR (or multiple PRs for a split plan):

- keep the title short and repo-appropriate,
- include `Plan issue: #<issue-number>` in the body of every PR,
- for single-PR implementations, include `Closes #<issue-number>` in the body,
- for split plans, use `Part of #<issue-number>` on earlier PRs and `Closes #<issue-number>` only on the final PR,
- summarise the approved plan and the implementation,
- when splitting, clearly state which part of the plan this PR covers (e.g. "Part 1: Fix default tab", "Part 2: Add browser history routing"),
- list the validation you ran,
- identify yourself clearly as the automated implementation step.

## Blocked-path comment

If you cannot produce a safe PR, leave one issue comment that:

- starts with `### 🤖 Implementation Blocked`,
- states the exact blocker,
- says what a maintainer needs to clarify or change,
- stays concise and operational.

## Constraints

- Prefer the approved plan over creative alternatives.
- Preserve existing behaviour outside the scoped change.
- Do not merge the PR yourself.
- Do not edit planning labels or planning comments.
- Do not create a PR with empty or low-confidence changes just to satisfy the workflow.
