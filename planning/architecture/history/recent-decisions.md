# Recent Decisions

## 2026-04-08 — Issue #270 (Apple live transcription clears text after speech pause)
Approved. Fix is scoped to `iOSLiveTranscriber.swift` only. Existing `committedText` accumulation pattern is the right seam; two gaps to close: (1) error callback path needs to commit `lastFormattedString` before returning, (2) `commitIfImplicitReset` threshold (>= 10 chars) doesn't protect short utterances. No cross-module changes needed.

## 2026-04-08 — Issue #246 (Incremental transcript append)
Approved. Fix is scoped to `TranscriptionManager.swift`. Deepgram path (line 653) is append-only — incremental O(1) safe. AssemblyAI path (line 1195) has replace/append branches — rebuild only on replace, append otherwise. `buildResult` is cold path, leave as-is. No module boundaries crossed, no new abstractions.

## 2026-04-08 — Issue #276 (CI Failure Doctor — Architecture transient failure)
Issue #276 carries only `automation` and `ci` labels — no `planning:` labels and no Planning Kickoff comment. It documents a transient CLI non-zero exit from the Issue Planning - Architecture workflow (run #24122401805). Architecture review does not apply per the do-nothing rule. This is the same recurring transient pattern documented in #272, #166, #158 per the issue body.

## 2026-04-08 — PR #277 (Architecture PR Plan Review)
PR #277 is not accessible via the GitHub API (all read methods return empty). Does not appear in open or closed PR list. Comment ID 4205723022 was the trigger. No action taken per protocol: cannot verify live PR context or linked planning issue. Same pattern as #209, #252, #256.

## 2026-04-08 — Issue #279 (Perf Improver — HistoryManager O(1) stats and WAL fix)
Issue #279 is a closed bot-generated issue from the Daily Perf Improver workflow with labels `automation`, `performance`, `agentic-workflows`. No `planning:` labels and no Planning Kickoff comment. Architecture review does not apply per the do-nothing rule. Issue is also already closed as not_planned.

## 2026-04-08 — PR #282 (fix(ios): add missing SpeakCore import)
PR #282 is already closed (merged). The workflow was triggered by `issue_comment` on a closed PR. Per protocol, no action taken. The fix was a single import change in `SpeakiOSApp.swift` to resolve `OpenClawClient` type not found. Same inaccessible-via-API pattern as #209, #252, #277.

## 2026-04-09 — PR #284 (Architecture PR Plan Review trigger)
PR #284 is not accessible via the GitHub API (all read methods return empty). Does not appear in open or closed PR list. Comment ID 4212100470 was the trigger. No action taken per protocol: cannot verify live PR context or linked planning issue. Same recurring inaccessible-via-API pattern as #209, #252, #277, #282.

## 2026-04-09 — Issue #263 (O(1) incremental stats and WAL fix in HistoryManager)
Approved. Single file (`HistoryManager.swift`), single module (`SpeakApp`). WAL fix correctly uses `pendingWrites` (already canonical in-memory state) eliminating redundant disk read. Stats fix wires up three existing `updateStatisticsFor*` methods that were present but unused. New `effectiveDuration(for:)` private helper aligns incremental behavior with full `calculateStatistics`. No module boundaries crossed, no new seams. Issue is closed (bot couldn't create PR) but planning labels still active; approved regardless.

## 2026-04-09 — PR #271 (Architecture PR Plan Review trigger)
PR #271 is not accessible via the GitHub API (all read methods: get, get_comments, get_diff, get_files, get_reviews return empty). Issue #271 also returns empty. Does not appear in open or closed PR list via search. Comment ID 4212471027 was the trigger. No action taken per protocol: cannot verify live PR context or linked planning issue. Same recurring inaccessible-via-API pattern as #209, #252, #277, #282, #284.

## 2026-04-09 — Issue #270 (re-approval after second /doit)
Second `/doit` on #270 reset all planning labels that were already fully approved on 2026-04-08. Plan was identical; re-approved immediately. Pattern: `/doit` resets the label machine even on already-approved issues — this is expected workflow behavior, not a bug.
