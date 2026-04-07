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
