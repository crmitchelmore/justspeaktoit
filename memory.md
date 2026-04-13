# Perf Improver Memory

## Commands
`swift build --target SpeakCore` ✅ in sandbox (ModelCatalog.swift compiles cleanly)
Full build/test blocked by Sentry firewall (os.log in AudioBufferPool on Linux).
SwiftLint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. MEDIUM: HistoryView.apply(filter:) builds intermediate strings on every search keystroke; short-circuit with early exits
2. (Exhausted previous items: #201 closed not_planned, #252 closed completed, #246 handled by PR #325)

## Monthly: Issue #312 for April 2026 (updated 2026-04-13 run).

## Round-Robin
Last (2026-04-13 run 7): Tasks 2,3,7
Next: Tasks 1,4,5,6,7

## Open PRs
- NEW: perf-assist/modelcatalog-cached-alloptions (2026-04-13) — cache allOptions + O(1) friendlyName

## Notes
GitHub MCP read tools functional for list/read operations.
Previous PR #311 (branch perf-assist/incremental-transcript-append-291822ed02e85aa1) is open as an issue — superseded by PR #325 from issue-ready-to-pr workflow.
Issue #246 had /doit — PR #325 created by issue-ready-to-pr.
Issues #201 (not_planned) and #252 (completed) are closed — respect maintainer decisions.
