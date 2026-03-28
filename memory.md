# Perf Improver Memory

## Commands
- Build/Test: blocked by network in CI (Sentry binary download)
- Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. PersonalLexiconService NSRegularExpression cache (HIGH) — branch: perf-assist/personal-lexicon-regex-cache-715979ce326a0a84
2. HistoryManager incremental stats (MEDIUM) — branch: perf-assist/history-manager-incremental-stats-d00c0243d51f9883
3. HistoryManager.update() redundant sort (MEDIUM)
4. TranscriptionManager Deepgram string rebuild (~line 653)

## Open Work
- `perf-assist/text-processor-casefold-search`: PR submitted 2026-03-28

## Round-Robin (2026-03-28)
Last: Task 3, Task 7. Next: Task 2, 5, 6

## Monthly Issue: #153
