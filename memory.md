# Perf Improver Memory

## Commands
`swift build --target SpeakCore` passes. `make build`/`make test` blocked by firewall.
Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. MEDIUM HistoryManager incremental stats+WAL — #238
2. MEDIUM NSRegularExpression cache (PersonalLexiconService+OpenClaw) — #239
3. MEDIUM WordDiffer LCS lowercased precompute — #240
4. MEDIUM TranscriptionTextProcessor .caseInsensitive — #201
5. MEDIUM PronunciationManager NSRegex cache TTS — new ~#246
6. LOW DeepgramLiveController O(N) transcript rebuild — new ~#247
7. INFRA No XCTest measure{} blocks exist

## Duplicates to close
#184→#238, #152/#216/#227→#239, #215→#240, #204→#201, #233→#238

## Monthly Issue
#228 open (April 2026). Updated 2026-04-04.

## Round-Robin
Last run (2026-04-04): Tasks 1,2,6,7. Next: Tasks 3,4,5,7
Priority for Task 3: implement #238 (HistoryManager) or #239 (NSRegex cache)
