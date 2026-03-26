---
name: Repository Context Refresh
description: Update each planning role's repository-context.md with current codebase facts
on:
  schedule: weekly
  workflow_dispatch:
permissions:
  contents: read
  issues: read
  pull-requests: read

network: defaults

tools:
  bash: ["*"]
  github:
    toolsets: [default]
  repo-memory:
    branch-name: planning/product
    description: "Planning role memory for context refresh"
    file-glob:
      - planning/product/*.md
      - planning/product/**/*.md
    max-file-size: 262144
    max-patch-size: 65536
    allowed-extensions: [".md", ".json"]

safe-outputs: {}

timeout-minutes: 15
engine: copilot
---
# Repository Context Refresh

You maintain the `repository-context.md` file for a planning role in `${{ github.repository }}`. This file gives the role grounded, verified facts about the codebase so it can judge issues without re-inspecting the repo every time.

## What to capture

Inspect the repository and record durable facts that repeatedly affect planning decisions:

### Technology stack
- Runtime, framework, and language versions (check `Package.swift`, `*.xcodeproj`, etc.)
- Key dependencies and their purposes
- Build and test toolchain

### Module structure
- Top-level directory layout and what each directory owns
- App targets vs framework targets
- Key entry points and architecture patterns

### Data and auth
- Data persistence approach (Core Data, UserDefaults, Keychain, etc.)
- Authentication and API integration patterns
- Key configuration and environment variable sources

### Deployment
- CI/CD pipeline shape (build → test → archive → release)
- Distribution method (App Store, TestFlight, direct)
- Supported platforms and minimum OS versions

### Agentic system
- Number and names of planning agents
- Memory branch structure
- Daily improvement agents active

## How to update

1. Read the existing `repository-context.md` from memory.
2. Inspect the repository using bash commands (`cat`, `ls`, `head`, `grep`).
3. Compare each section against reality.
4. Update only facts that have changed or are missing.
5. Add a date header: `<!-- Last refreshed: YYYY-MM-DD -->`.
6. Keep the file under 4 KB. Prefer concise bullet points over prose.

## Operating constraints

- Only record verifiable facts, not opinions or aspirations.
- Do not record secrets, tokens, or sensitive configuration values.
- If a fact cannot be verified from the repository contents, omit it.
- Keep the same section structure across refreshes for diff-friendliness.
