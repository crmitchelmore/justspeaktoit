# Perf Improver Memory

## Commands
- Build/Test: blocked by network in CI (Sentry binary download)
- Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog (priority order)
1. HIGH PersonalLexiconService regex cache — issue #152; draft PR branch: perf-assist/personal-lexicon-regex-cache (2026-03-30)
2. MEDIUM HistoryManager incremental stats — issue #184
3. MEDIUM TranscriptionTextProcessor lowercased+distance — issue #201
4. MEDIUM TranscriptionTextProcessor clipboard String alloc — issue #204
5. MEDIUM WordDiffer LCS lowercased — draft PR branch: perf-assist/word-differ-lcs-lowercase-precompute (2026-03-30)
6. LOW HistoryManager.update() redundant sort
7. LOW TranscriptionManager Deepgram string rebuild ~line 653

## Open Work
- perf-assist/personal-lexicon-regex-cache: draft PR submitted 2026-03-30 (closes #152)
- perf-assist/word-differ-lcs-lowercase-precompute: draft PR submitted 2026-03-30

## Round-Robin
Last run (2026-03-30): Task 3, 4, 7. Next: Task 2, 5, 6

## Monthly Issue: #153
