# Perf Improver Memory

## Commands
`swift build --target SpeakCore` ✅ in sandbox (compiles cleanly).
Full build/test blocked by Sentry firewall (os.log in AudioBufferPool on Linux).
SwiftLint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. MEDIUM: HistoryView.availableModels re-computed on every render; could be derived once when historyItems changes
2. (Previous items exhausted or implemented)

## Monthly: Issue #312 for April 2026 (updated 2026-04-14 run).

## Round-Robin
Last (2026-04-14 run 8): Tasks 1,4,5,6,7 (+ Task 3: new PR for HistoryView filter)
Next: Tasks 2,3,7

## Open PRs
- #332: perf-assist/modelcatalog-cached-alloptions (2026-04-13) — cache allOptions + O(1) friendlyName
- NEW (branch perf-assist/history-filter-early-exit, 2026-04-14): early-exit HistoryView filter, eliminate per-item string allocations

## Notes
GitHub MCP read tools functional for list/read operations.
Issue #311 is an old issue/PR placeholder for incremental transcript append — superseded by PR #325.
Issues #201 (not_planned) and #252 (completed) are closed — respect maintainer decisions.
PR #325 covers incremental transcript append (closes #246).
New ElevenLabs integration PRs #362-#366 are active in the repo (issue-ready-to-pr).
