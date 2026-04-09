# Recent Decisions

## 2026-04-07 — Issue #169 (AudioBufferPool tests)
Issue #169 is not a pull request — it was created by the Daily Test Improver workflow and describes new tests for `AudioBufferPool`. The PR lane workflow was triggered by an `issue_comment` on this issue, but the trigger condition requires the comment to belong to a PR. No action taken. Architecture review does not apply here.

## 2026-04-07 — PR #209
PR #209 is not accessible via the GitHub API (returns empty results for all methods: get, get_diff, get_files, get_comments, get_reviews). It does not appear in the open or closed PR list. It is likely merged, deleted, or converted. No action taken per protocol: cannot verify live PR context.

## 2026-04-07 — Issue #260 ([Test Improver] Codable round-trips)
Issue #260 carries only `automation`, `testing`, and `agentic-workflows` labels — no `planning:` labels and no Planning Kickoff comment. Architecture review does not apply per the do-nothing rule.

## 2026-04-07 — PR #252
PR #252 is not accessible via the GitHub API (all read methods: get, get_comments, get_diff, get_files return empty results). It does not appear in the open or closed PR list. Cannot verify live PR context or linked planning issue. No action taken per protocol.

## 2026-04-07 — Issue #212 ([Test Improver] Add AudioBufferPool unit tests)
Issue #212 is not a pull request — it's a test-improver automation issue with labels `automation`, `testing`, `agentic-workflows`. The workflow was triggered by an `issue_comment` on this issue. Per protocol, no action taken: comment belongs to an issue, not a PR.

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

## 2026-04-09 — Issue #285 (trigger: issue_comment #4212101482)
Issue #285 is not accessible via the GitHub API (both `get` and `get_comments` return empty results). Cannot verify labels, body, or planning comment history. Per protocol, no action taken. Same recurring inaccessible-via-API pattern as #209, #252, #277, #282, #284. This pattern now spans at least 6 issues/PRs; likely a systemic API access constraint in this workflow environment.
