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

## 2026-04-08 — Issue #277 (CI Failure Doctor — sentry-cocoa bump)
Issue #277 carries only `automation` and `ci` labels — no `planning:` labels and no Planning Kickoff comment. Created by CI Failure Doctor for a transient CI failure after dependabot bumped sentry-cocoa 9.8.0 → 9.9.0. Issue is already closed. Architecture review does not apply per the do-nothing rule. Same pattern as #276, #260.
