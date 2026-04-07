# Repository Context

## Project
justspeaktoit — macOS + iOS voice-to-text app (Swift, SwiftUI)
- macOS app: SpeakApp (SwiftPM executable)
- iOS app: SpeakiOSLib + SpeakiOSApp
- Shared core: SpeakCore

## Planning Workflow
- 7 technical reviewers: Product (Alex), Security (Priya), Performance (Theo),
  Code Quality (Casey), Architecture (Morgan), Reliability (Jordan), Design (Riley)
- EM (Sam) facilitates, does not approve
- Kickoff comment triggers role reviews; EM only comments when ≥3 roles in and team is stuck
- Issue labels drive workflow triggers

## Release Cadence
- macOS: automated via conventional commits → mac-v* tags
- iOS: manual TestFlight workflow dispatch
- Non-releasable types: chore, docs, ci, style, test, refactor, build

## Agentic Workflows
- Daily agents: perf-improver, test-improver, doc-updater, repo-status
- Planning agents: product, security, performance, quality, architecture, reliability, design, EM
- Coordination agent monitors backlog health

## GitHub MCP Tooling Issue (observed 2026-04-07)
GitHub MCP tools (issue_read, list_issues) consistently return [] for issues #202, #244, #250, #239.
This appears to be a persistent infrastructure issue, not issue-specific.
Cannot verify planning preconditions without issue data — defaulting to noop.
