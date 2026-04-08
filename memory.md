# Perf Improver Memory

## Commands
SwiftLint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`
Full build blocked by Sentry firewall (binary xcframework download).
`swift build --target SpeakCore` ✅ passes in sandbox.
`swift test --filter SpeakAppTests` ✅ passes in sandbox.

## Backlog
1. MEDIUM #240: WordDiffer LCS lowercased precompute
2. MEDIUM #201: TranscriptionTextProcessor .caseInsensitive
3. MEDIUM #252: NSRegex cache lexicon/TTS
4. LOW #246: DeepgramLiveController O(N) rebuild
5. INFRA #258: WordDiffer measure{} — branch perf-assist/worddifer-measure-baselines (PR pending)

## Duplicates
#233/#238/#184→#263, #152/#216/#227→#252, #215→#240, #204→#201

## Monthly: #228 April 2026. Updated 2026-04-08.

## Round-Robin
Last (2026-04-08 run 2): Tasks 3,4,5,7. Next: Tasks 1,2,6,7
Task 3 next priority: #240 WordDiffer lowercased precompute

## Completed
- #263 HistoryManager O(1) stats+WAL: PR submitted branch perf-assist/historymanager-o1-stats-wal (2026-04-08 run 2)
