# Perf Improver Memory

## Commands
`swift build --target SpeakCore` ✅ in sandbox (compiles cleanly).
Full build/test blocked by Sentry firewall (os.log in AudioBufferPool on Linux).
SwiftLint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
- All known opportunities addressed. Still scanning for new ones.

## Monthly: Issue #312 for April 2026 (updated 2026-04-16 run).

## Round-Robin
Last (2026-04-16 run 10): Tasks 3,7
Next: Tasks 1,2,4,5,6,7

## Open PRs
- NEW (branch perf-assist/pronunciation-regex-cache, 2026-04-16): cache NSRegularExpression in PronunciationManager; avoid re-compiling per TTS call per entry

## Notes
GitHub MCP read tools functional for list/read operations.
PRs #332, #368, #382, #390 all merged by crmitchelmore on 2026-04-16.
Issue #311 closed by PR #390 (incremental AssemblyAI append).
Issue #312 is April 2026 monthly summary.
