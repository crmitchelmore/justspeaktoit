# Recent Decisions

## 2026-04-11 — Issue #297 (TTS Provider Shared Infrastructure Gaps)
Closed bot-generated quality issue with labels `quality`, `automated-analysis`, `technical-debt`. No `planning:` labels and no Planning Kickoff comment. No action taken per do-nothing rule. Maintainer closed issue as backlog cleanup — too broad for a single issue; should be smaller scoped issues if prioritised later.

## 2026-04-10 — Issue #157 re-approval after /doit cycle
Re-approved after /doit reset labels. Plan is structurally identical to first round (2026-03-25). New observation: Product (idle/ready visibility) and Design (recording+failure visibility) diverged on health panel phase. View-layer only — no architectural implication. Approved without change.

## 2026-04-08 — Issue #270 (Apple live transcription clears text after speech pause)
Approved. Fix is scoped to `iOSLiveTranscriber.swift` only. Existing `committedText` accumulation pattern is the right seam; two gaps to close: (1) error callback path needs to commit `lastFormattedString` before returning, (2) `commitIfImplicitReset` threshold (>= 10 chars) doesn't protect short utterances. No cross-module changes needed.

## 2026-04-08 — Issue #246 (Incremental transcript append)
Approved. Fix is scoped to `TranscriptionManager.swift`. Deepgram path (line 653) is append-only — incremental O(1) safe. AssemblyAI path (line 1195) has replace/append branches — rebuild only on replace, append otherwise. `buildResult` is cold path, leave as-is. No module boundaries crossed, no new abstractions.

## 2026-04-08–09 — No-action pattern: #276, #277, #279, #282, #284
All five were either: CI/automation issues with no `planning:` labels; PRs inaccessible via API; or closed PRs triggered by issue_comment. No action taken per protocol (same as prior pattern for #209, #252, #256).

## 2026-04-09 — Issue #263 (O(1) incremental stats and WAL fix in HistoryManager)
Approved. Single file (`HistoryManager.swift`), single module (`SpeakApp`). WAL fix correctly uses `pendingWrites` (already canonical in-memory state) eliminating redundant disk read. Stats fix wires up three existing `updateStatisticsFor*` methods that were present but unused. New `effectiveDuration(for:)` private helper aligns incremental behavior with full `calculateStatistics`. No module boundaries crossed, no new seams. Issue is closed (bot couldn't create PR) but planning labels still active; approved regardless.

## 2026-04-09 — PR #271 (Architecture PR Plan Review trigger)
PR #271 is not accessible via the GitHub API (all read methods: get, get_comments, get_diff, get_files, get_reviews return empty). Issue #271 also returns empty. Does not appear in open or closed PR list via search. Comment ID 4212471027 was the trigger. No action taken per protocol: cannot verify live PR context or linked planning issue. Same recurring inaccessible-via-API pattern as #209, #252, #277, #282, #284.

## 2026-04-09 — Issue #270 (re-approval after second /doit)
Second `/doit` on #270 reset all planning labels that were already fully approved on 2026-04-08. Plan was identical; re-approved immediately. Pattern: `/doit` resets the label machine even on already-approved issues — this is expected workflow behavior, not a bug.

## 2026-04-11 — PR #292 (Architecture PR Plan Review trigger)
PR #292 not accessible via API (pull_request_read and list_pull_requests open/closed all return empty). GitHub context shows `pull-request-number: #` (blank), confirming the triggering comment was on an issue, not a PR. Per protocol, no action taken. Comment ID 4228852425, workflow run 24278128349. Same recurring inaccessible-via-API / issue-not-PR pattern as #209, #252, #277, #282, #284.
