# Perf Improver Memory

## Commands
- Build: `swift build` / `make build`
- Test: `make test` (fails in CI - network)
- Lint: `swift package plugin swiftlint --strict --target SpeakApp`

## Backlog
1. ✅ PersonalLexiconService regex cache - branch exists, PR creation pending
2. ✅ HistoryManager incremental stats + WAL read fix - PR submitted 2026-03-26
3. HistoryManager redundant sort in update() (~line 422)
4. TranscriptionManager Deepgram string rebuild (~line 653)
5. TranscriptionTextProcessor O(n) distance call (~line 70)

## Round-Robin (2026-03-26)
Done: Task 3, 4, 7. Next: Task 1, 5, 6

## Notes
- No benchmarks; all measurement must be synthetic
- `perf:` commits trigger mac auto-release
- safeoutputs create_pull_request stages PR at workflow completion
- Branch already on remote: can't create PR via safeoutputs (needs local unpushed commits)
