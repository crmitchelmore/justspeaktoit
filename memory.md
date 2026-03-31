# Perf Improver Memory

## Commands
Build/Test: blocked in CI (Sentry binary download firewall).
Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`

## Backlog
1. HIGH PersonalLexiconService NSRegularExpression cache — issue #216
2. HIGH OpenClawChatCoordinator+HandsFree.removingAcknowledgementKeyword — NSRegularExpression per call (new 2026-03-31)
3. MEDIUM HistoryManager incremental stats (3 dead O(1) methods unused)
4. MEDIUM TranscriptionTextProcessor caseInsensitive search — issue #201
5. MEDIUM TranscriptionTextProcessor clipboard alloc — issue #204
6. MEDIUM WordDiffer LCS lowercased — issue #215
7. LOW HistoryManager.update() redundant sort
8. LOW TranscriptionManager Deepgram string rebuild ~line 653

## Open Issues
#201, #204, #215, #216 — all open, no human comments as of 2026-03-31.

## Round-Robin
Last run (2026-03-31): Tasks 2,5,6,7. Next: Tasks 3,4,7

## Monthly Issue
#153 (March 2026, open)
