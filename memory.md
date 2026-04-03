# Perf Improver Memory

## Commands
Build: `swift build --target SpeakCore` (passes). Full build blocked by Sentry firewall.
Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog (remaining)
1. MEDIUM TranscriptionTextProcessor — issues #201, #204 (no branches yet)
2. LOW TranscriptionManager Deepgram string rebuild

## PRs Submitted
- 2026-04-03: incremental stats (closes #184), regex cache (closes #227), WordDiffer LCS (closes #215)

## Open Tracking Issues
#201, #204 open (work remaining). #152, #216 duplicates of #227 (maintainer should close).

## Round-Robin
Last run (2026-04-03): Tasks 3,7. Next: Tasks 1,2,5,6,7

## Monthly Issue
April 2026 #228 open. Last updated 2026-04-03.
