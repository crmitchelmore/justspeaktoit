# Perf Improver Memory

## Commands
SwiftLint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`
Full build blocked by Sentry firewall (binary xcframework download - now 9.9.0, was 9.8.0).
`swift build --target SpeakCore` — blocked by same Sentry firewall in current sandbox.
`swift test --filter SpeakAppTests` — blocked by same Sentry firewall in current sandbox.

## Backlog
1. MEDIUM #240: WordDiffer LCS lowercased precompute — BRANCH READY (perf-assist/worddifer-lcs-precompute-v2, commit 92fa765), needs push+PR
2. MEDIUM #201: TranscriptionTextProcessor .caseInsensitive
3. MEDIUM #252: NSRegex cache lexicon/TTS (PersonalLexiconService + PronunciationManager)
4. LOW #246: DeepgramLiveController O(N) rebuild

## Duplicates
#233/#238/#184→#263, #152/#216/#227→#252, #215→#240, #204→#201

## Monthly: #228 April 2026. Updated 2026-04-09.

## Round-Robin
Last (2026-04-10 run 4): Tasks 3,7 — safeoutputs MCP unavailable, no PR/issue updated.
Next: Tasks 3,4,5,7 — retry PR creation for #240 branch; verify #258/#263 PR status.

## Open PRs (verify current state)
- perf-assist/worddifer-measure-baselines-v2: measure baselines for WordDiffer (closes #258) — created 2026-04-09
- perf-assist/historymanager-o1-stats-wal-v2: O(1) HistoryManager stats+WAL (closes #263) — created 2026-04-09
- perf-assist/worddifer-lcs-precompute-v2: LCS lowercased precompute (closes #240) — committed 2026-04-10, NOT PUSHED

## Completed
- #258/#263: Both converted to clean PRs on 2026-04-09 run 3
- #240: Optimization implemented 2026-04-10; pending push+PR

## safeoutputs MCP Note
MCP unavailable in runs seen so far. Sub-agents also cannot access them.
