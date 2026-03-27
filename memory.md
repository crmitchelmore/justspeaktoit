# Perf Improver Memory

## Commands
- Build/Test: blocked by network in CI (Sentry binary download)
- Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. PersonalLexiconService NSRegularExpression cache (HIGH)
2. HistoryManager.update() redundant sort (MEDIUM)
3. HistoryManager incremental stats - wire existing dead methods (MEDIUM)
4. TranscriptionManager Deepgram string rebuild (~line 653)

## Open PRs
- Branch: perf-assist/text-processor-casefold-search (PR staged 2026-03-27)

## Round-Robin (2026-03-27)
Next: Task 1, 2, 5, 6

## Monthly Issue: #153
