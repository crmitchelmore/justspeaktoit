# Perf Improver Memory

## Commands (validated 2026-03-25)
- Build: `swift build` / `make build`
- Test: `make test` (fails in CI - network blocked, infrastructure issue)
- Lint: `swift package plugin swiftlint --strict --target SpeakApp`

## Backlog (priority order)
1. ✅ PersonalLexiconService regex caching - PR submitted 2026-03-25
2. HistoryManager stats recalculation - full recalc on every mutation, dead incremental methods exist (~line 415)
3. HistoryManager WAL I/O - full read/write on every op (~line 184)
4. HistoryManager redundant sort on every update (~line 425)
5. Logging.swift UserDefaults on every call (~line 27)
6. TranscriptionManager Deepgram string rebuild on every segment (~line 653)

## Round-Robin State (2026-03-25)
Done: Task 1, 2, 3, 7
Next: Task 4, 5, 6

## Notes
- No existing benchmarks; all measurement must be synthetic/manual
- `perf:` commits trigger mac auto-release
