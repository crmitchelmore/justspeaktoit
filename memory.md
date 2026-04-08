# Perf Improver Memory

## Commands
SwiftLint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`
Full build blocked by Sentry firewall (binary xcframework download).

## Backlog
1. HIGH #263: HistoryManager O(n)→O(1) stats+WAL
2. MEDIUM #240: WordDiffer LCS lowercased precompute
3. MEDIUM #201: TranscriptionTextProcessor .caseInsensitive
4. MEDIUM #252: NSRegex cache lexicon/TTS
5. LOW #246: DeepgramLiveController O(N) rebuild
6. INFRA #258: WordDiffer measure{} — PR branch perf-assist/worddifer-measure-baselines

## Duplicates
#233/#238/#184→#263, #152/#216/#227→#252, #215→#240, #204→#201

## Monthly: #228 April 2026. Updated 2026-04-08.

## Round-Robin
Last (2026-04-08): Tasks 1,2,6,7. Next: Tasks 3,4,5,7
Task 3 priority: #263 HistoryManager O(1)
Note: sandbox firewall may block branch push
