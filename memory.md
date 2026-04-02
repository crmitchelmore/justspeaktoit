# Perf Improver Memory

## Commands
Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict --target SpeakApp`
Build: `swift build --target SpeakCore` (passes). Full build blocked by Sentry firewall in CI.

## Backlog
1. MEDIUM WordDiffer LCS lowercased — issue #215
2. MEDIUM TranscriptionTextProcessor caseInsensitive — issue #201
3. MEDIUM TranscriptionTextProcessor clipboard alloc — issue #204
4. MEDIUM NSRegularExpression caching in PersonalLexiconService/OpenClawChatCoordinator — issue #227
5. LOW HistoryManager.update() redundant sort
6. LOW TranscriptionManager Deepgram string rebuild ~line 653

## Open Issues
#201, #204, #215, #227 open. #152, #216 are duplicates of #227 (maintainer should close).
#184 — closed by PR (perf-assist/incremental-history-stats, run 2026-04-02).

## Round-Robin
Last run (2026-04-02): Tasks 3,7. Next: Tasks 1,2,5,6,7

## Monthly Issue
April 2026 monthly issue #228 open. Last updated 2026-04-02.
