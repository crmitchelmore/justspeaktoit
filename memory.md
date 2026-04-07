# Perf Improver Memory

## Commands
Full build blocked by Sentry firewall (binary xcframework download).
Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. IN PROGRESS #184: HistoryManager O(n)→O(1) stats+WAL — PR branch perf-assist/historymanager-incremental-stats
2. MEDIUM #240: WordDiffer LCS lowercased precompute
3. MEDIUM #201: TranscriptionTextProcessor .caseInsensitive
4. MEDIUM #239/#247: NSRegex cache in lexicon/TTS
5. LOW #246: DeepgramLiveController O(N) rebuild

## Duplicates
#233→#238, #152/#216/#227→#239, #215→#240, #204→#201

## Monthly Issue: #228 (April 2026). Updated 2026-04-07.

## Round-Robin
Last run (2026-04-07): Tasks 3,4,5,7. Next: Tasks 1,2,6,7
Priority for Task 3: #240 WordDiffer LCS
