# Perf Improver Memory

## Commands
- Build/Test: blocked by network in CI (Sentry binary download)
- Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. PersonalLexiconService NSRegularExpression cache (HIGH) — open issue #152; branch: perf-assist/personal-lexicon-regex-cache-715979ce326a0a84
2. HistoryManager incremental stats (MEDIUM) — open issue #184; branch: perf-assist/history-manager-incremental-stats-d00c0243d51f9883
3. TranscriptionTextProcessor lowercased+distance fix (MEDIUM) — open issue #201; branch: perf-assist/text-processor-casefold-search
4. TranscriptionTextProcessor redundant String alloc in clipboard match (MEDIUM) — open issue #204
5. WordDiffer repeated .lowercased() in LCS inner loop (MEDIUM) — NEW 2026-03-29; buildLCSTable calls .lowercased() on every comparison O(m*n) allocs; pre-compute once
6. HistoryManager.update() redundant sort (LOW)
7. TranscriptionManager Deepgram string rebuild (~line 653)

## Open Work
- None (no open Perf Improver PRs as of 2026-03-29)

## Tracking Issues
- #152: PersonalLexiconService NSRegularExpression cache
- #184: HistoryManager incremental stats
- #201: TranscriptionTextProcessor lowercased+distance
- #204: TranscriptionTextProcessor clipboard String alloc

## Round-Robin (2026-03-29)
Last: Task 2, 5, 6, 7. Next: Task 3, 4

## Monthly Issue: #153
