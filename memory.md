# Perf Improver Memory

## Commands
`swift build --target SpeakCore` passes. `make build`/`make test` blocked by firewall.
Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. MEDIUM HistoryManager incremental stats+WAL — #238
2. MEDIUM WordDiffer LCS lowercased precompute — #240
3. MEDIUM TranscriptionTextProcessor .caseInsensitive — #201
4. LOW DeepgramLiveController O(N) transcript rebuild — #246
5. INFRA No XCTest measure{} blocks exist

## Duplicates to close
#184→#238, #152/#216/#227→#239, #215→#240, #204→#201, #233→#238

## Monthly Issue
#228 open (April 2026). Updated 2026-04-05.

## Completed PRs
- branch perf-assist/cache-nsregularexpression: NSRegex cache in PersonalLexiconService + PronunciationManager. Closes #239, #247. Created 2026-04-05.

## Round-Robin
Last run (2026-04-05): Tasks 3,4,5,7. Next: Tasks 1,2,6,7
Priority for Task 3: implement #238 (HistoryManager) or #240 (WordDiffer)
