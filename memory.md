# Perf Improver Memory

## Commands
`swift build --target SpeakCore` passes. Full build blocked by Sentry firewall.
Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. MEDIUM HistoryManager O(n)→O(1) stats+WAL — #238
2. MEDIUM WordDiffer LCS lowercased precompute — #240
3. MEDIUM TranscriptionTextProcessor .caseInsensitive — #201
4. MEDIUM NSRegex cache in lexicon/TTS — #239, #247
5. LOW DeepgramLiveController O(N) rebuild — #246

## Duplicates to close
#184→#238, #152/#216/#227→#239, #215→#240, #204→#201, #233→#238

## Monthly Issue: #228 (April 2026). Updated 2026-04-06.

## Completed PRs
- perf-assist/cache-nsregularexpression: NSRegex cache. Closes #239,#247. 2026-04-05.
- perf-assist/xctest-measure-baselines: XCTest measure{} for WordDiffer. 2026-04-06.

## Round-Robin
Last run (2026-04-06): Tasks 1,2,6,7. Next: Tasks 3,4,5,7
Priority for Task 3: #238 HistoryManager or #240 WordDiffer LCS
