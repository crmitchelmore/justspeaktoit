# Perf Improver Memory

## Commands
`swift build --target SpeakCore` ✅ in sandbox (compiles cleanly).
Full build/test blocked by Sentry firewall (os.log in AudioBufferPool on Linux).
SwiftLint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. MEDIUM: PronunciationManager.applySimpleReplacement creates NSRegularExpression on every call (per entry, per TTS invocation); cache compiled regexes keyed on (pattern, caseSensitive)

## Monthly: Issue #312 for April 2026 (updated 2026-04-15 run).

## Round-Robin
Last (2026-04-15 run 9): Tasks 2,3,7
Next: Tasks 1,4,5,6,7

## Open PRs
- #332: perf-assist/modelcatalog-cached-alloptions (2026-04-13) — cache allOptions + O(1) friendlyName
- #368: perf-assist/history-filter-early-exit (2026-04-14) — early-exit HistoryView filter, eliminate per-item string allocations
- NEW (branch perf-assist/historyview-cache-available-models, 2026-04-15): cache availableModels as @State, recompute only on historyItems change

## Notes
GitHub MCP read tools functional for list/read operations.
Issue #311 is an old issue/PR placeholder for incremental transcript append — superseded by PR #325.
Issues #201 (not_planned) and #252 (completed) are closed — respect maintainer decisions.
PR #325 covers incremental transcript append (closes #246).
New ElevenLabs integration PRs #362-#366 are active in the repo (issue-ready-to-pr).
