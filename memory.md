# Perf Improver Memory

## Commands
Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`
Build: `swift build --target SpeakCore` (passes). Full build blocked by Sentry firewall in CI.

## Backlog
1. MEDIUM HistoryManager incremental stats — issue #184
2. MEDIUM WordDiffer LCS lowercased — issue #215
3. MEDIUM TranscriptionTextProcessor caseInsensitive — issue #201
4. MEDIUM TranscriptionTextProcessor clipboard alloc — issue #204
5. LOW HistoryManager.update() redundant sort
6. LOW TranscriptionManager Deepgram string rebuild ~line 653

## Open Issues
#201, #204, #215, #184 open. #216 open — PR submitted 2026-04-01 to close it. #152 duplicate of #216.

## Round-Robin
Last run (2026-04-01): Tasks 3,4,7. Next: Tasks 1,2,5,6,7

## Monthly Issue
April 2026 monthly issue created. March #153 closed.
